{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 -
 - Advanced parser for declarations, module instantiations, and some statements.
 -
 - This module exists because the SystemVerilog grammar is not LALR(1), and
 - Happy can only produce LALR(1) parsers. This module provides an interface for
 - parsing a list of "DeclTokens" into `Decl`s, `ModuleItem`s, or `Stmt`s. This
 - works through a series of functions which have use a greater lookahead for
 - resolving the conflicts.
 -
 - Consider the following two module declarations:
 -  module Test(one two, three [1:0], four);
 -  module Test(one two, three [1:0]  four);
 -
 - When `{one} two ,` is on the stack, it is impossible to know whether to A)
 - shift `three` to add to the current declaration list; or B) to reduce the
 - stack and begin a new port declaration; without looking ahead more than 1
 - token.
 -
 - While I previously had some success dealing with these conflicts with
 - increasingly convoluted grammars, this became more and more untenable as I
 - added support for more SystemVerilog constructs.
 -
 - Because declarations and statements are subject to the same kind of
 - conflicts, this module additionally provides an interface for parsing
 - DeclTokens as either declarations or the basic statements (either assignments
 - or task/function calls) with which they can conflict. The initialization
 - portion of a for loop also allows for declarations and assignments, and so a
 - similar interface is provided for this case.
 -
 - This parser is very liberal, and so accepts some syntactically invalid files.
 - In the future, we may add some basic type-checking to complain about
 - malformed input files. However, we generally assume that users have tested
 - their code with a commercial simulator before running it through our tool.
 -}

module Language.SystemVerilog.Parser.ParseDecl
( DeclToken (..)
, parseDTsAsPortDecls
, parseDTsAsModuleItems
, parseDTsAsDecls
, parseDTsAsDecl
, parseDTsAsDeclOrStmt
, parseDTsAsDeclsOrAsgns
) where

import Data.List (findIndex, findIndices, partition)
import Data.Maybe (mapMaybe)

import Language.SystemVerilog.AST
import Language.SystemVerilog.Parser.Tokens (Position(..))

-- [PUBLIC]: combined (irregular) tokens for declarations
data DeclToken
    = DTComma    Position
    | DTAutoDim  Position
    | DTAsgn     Position AsgnOp (Maybe Timing) Expr
    | DTRange    Position (PartSelectMode, Range)
    | DTIdent    Position Identifier
    | DTPSIdent  Position Identifier Identifier
    | DTDir      Position Direction
    | DTType     Position (Signing -> [Range] -> Type)
    | DTParams   Position [ParamBinding]
    | DTInstance Position [PortBinding]
    | DTBit      Position Expr
    | DTConcat   Position [LHS]
    | DTStream   Position StreamOp Expr [LHS]
    | DTDot      Position Identifier
    | DTSigning  Position Signing
    | DTLifetime Position Lifetime
    deriving (Show, Eq)


-- entrypoints besides `parseDTsAsDeclOrStmt` use this to disallow `DTAsgn` with
-- a non-blocking operator, binary assignment operator, or a timing control
-- because we don't expect to see those assignment operators in declarations
forbidNonEqAsgn :: [DeclToken] -> a -> a
forbidNonEqAsgn tokens =
    if any isNonEqAsgn tokens
        then error $ "decl tokens contain bad assignment operator: " ++ show tokens
        else id
    where
        isNonEqAsgn :: DeclToken -> Bool
        isNonEqAsgn (DTAsgn _ op mt  _) =
            op /= AsgnOpEq || mt /= Nothing
        isNonEqAsgn _ = False


-- [PUBLIC]: parser for module port declarations, including interface ports
-- Example: `input foo, bar, One inst`
parseDTsAsPortDecls :: [DeclToken] -> ([Identifier], [ModuleItem])
parseDTsAsPortDecls pieces =
    forbidNonEqAsgn pieces $
    if isSimpleList
        then (simpleIdents, [])
        else (portNames declarations, map (MIPackageItem . Decl) declarations)
    where
        commaIdxs = findIndices isComma pieces
        identIdxs = findIndices isIdent pieces
        isSimpleList =
            all even identIdxs &&
            all odd commaIdxs &&
            odd (length pieces) &&
            length pieces == length commaIdxs + length identIdxs

        simpleIdents = map extractIdent $ filter isIdent pieces
        declarations = propagateDirections Input $ parseDTsAsDecls pieces

        extractIdent = \(DTIdent _ x) -> x

        propagateDirections :: Direction -> [Decl] -> [Decl]
        propagateDirections dir (decl @ (Variable _ InterfaceT{} _ _ _) : decls) =
            decl : propagateDirections dir decls
        propagateDirections lastDir (Variable currDir t x a me : decls) =
            decl : propagateDirections dir decls
            where
                decl = Variable dir t x a me
                dir = if currDir == Local then lastDir else currDir
        propagateDirections dir (decl : decls) =
            decl : propagateDirections dir decls
        propagateDirections _ [] = []

        portNames :: [Decl] -> [Identifier]
        portNames items = mapMaybe portName items
        portName :: Decl -> Maybe Identifier
        portName (Variable _ _ ident _ _) = Just ident
        portName CommentDecl{} = Nothing
        portName decl =
            error $ "unexpected non-variable port declaration: " ++ (show decl)


-- [PUBLIC]: parser for single (semicolon-terminated) declarations (including
-- parameters) and module instantiations
parseDTsAsModuleItems :: [DeclToken] -> [ModuleItem]
parseDTsAsModuleItems tokens =
    forbidNonEqAsgn tokens $
    if isElabTask $ head tokens then
        asElabTask tokens
    else if any isInstance tokens then
        parseDTsAsIntantiations tokens
    else
        map (MIPackageItem . Decl) $ parseDTsAsDecl tokens
    where
        isElabTask :: DeclToken -> Bool
        isElabTask (DTIdent _ x) = elem x elabTasks
            where elabTasks = ["$fatal", "$error", "$warning", "$info"]
        isElabTask _ = False
        isInstance :: DeclToken -> Bool
        isInstance (DTInstance{}) = True
        isInstance _ = False

-- internal; approximates the behavior of the elaboration system tasks
asElabTask :: [DeclToken] -> [ModuleItem]
asElabTask [DTIdent _ name, DTInstance _ args] =
    if name == "$info"
        then [] -- just drop them for simplicity
        else [Instance "ThisModuleDoesNotExist" [] name' Nothing args]
    where name' = "__sv2v_elab_" ++ tail name
asElabTask [DTIdent pos name] =
    asElabTask [DTIdent pos name, DTInstance pos []]
asElabTask tokens =
    error $ "could not parse elaboration system task: " ++ show tokens


-- internal; parser for module instantiations
parseDTsAsIntantiations :: [DeclToken] -> [ModuleItem]
parseDTsAsIntantiations (DTIdent _ name : tokens) =
    if not (all isInstanceToken rest)
        then error $ "instantiations mixed with other items: " ++ (show rest)
        else step rest
    where
        step :: [DeclToken] -> [ModuleItem]
        step [] = error $ "unexpected end of instantiation list: " ++ (show tokens)
        step toks =
            Instance name params x mr p : follow
            where
                (inst, toks') = span (not . isComma) toks
                (x, mr, p) = case inst of
                    [DTIdent _ a, DTRange _ (NonIndexed, s), DTInstance _ b] ->
                        (a, Just s , b)
                    [DTIdent _ a, DTInstance _ b] -> (a, Nothing, b)
                    _ -> error $ "unrecognized instantiation of " ++ name
                            ++ ": " ++ show inst
                follow = x `seq` if null toks' then [] else step (tail toks')
        (params, rest) =
            case head tokens of
                DTParams _ ps -> (ps, tail tokens)
                _             -> ([],      tokens)
        isInstanceToken :: DeclToken -> Bool
        isInstanceToken (DTInstance{}) = True
        isInstanceToken (DTRange{}) = True
        isInstanceToken (DTIdent{}) = True
        isInstanceToken (DTComma{}) = True
        isInstanceToken _ = False
parseDTsAsIntantiations tokens =
    error $
        "DeclTokens contain instantiations, but start with non-ident: "
        ++ (show tokens)


-- [PUBLIC]: parser for generic, comma-separated declarations
parseDTsAsDecls :: [DeclToken] -> [Decl]
parseDTsAsDecls tokens =
    forbidNonEqAsgn tokens $
    concat $ map finalize $ parseDTsAsComponents tokens


-- [PUBLIC]: used for "single" declarations, i.e., declarations appearing
-- outside of a port list
parseDTsAsDecl :: [DeclToken] -> [Decl]
parseDTsAsDecl tokens =
    forbidNonEqAsgn tokens $
    if length components /= 1
        then error $ "too many declarations: " ++ (show tokens)
        else finalize $ head components
    where components = parseDTsAsComponents tokens


-- [PUBLIC]: parser for single block item declarations or assign or arg-less
-- subroutine call statements
parseDTsAsDeclOrStmt :: [DeclToken] -> ([Decl], [Stmt])
parseDTsAsDeclOrStmt [DTIdent   pos   f] = ([], [traceStmt pos, Subroutine (Ident     f) (Args [] [])])
parseDTsAsDeclOrStmt [DTPSIdent pos p f] = ([], [traceStmt pos, Subroutine (PSIdent p f) (Args [] [])])
parseDTsAsDeclOrStmt (DTAsgn pos (AsgnOp op) mt e : tok : toks) =
    parseDTsAsDeclOrStmt $ (tok : toks) ++ [DTAsgn pos (AsgnOp op) mt e]
parseDTsAsDeclOrStmt tokens =
    if (isStmt (last tokens) || tripLookahead tokens) && maybeLhs /= Nothing
        then ([], [traceStmt pos, stmt])
        else (parseDTsAsDecl tokens, [])
    where
        pos = tokPos $ last tokens
        stmt = case last tokens of
            DTAsgn  _ op mt e -> Asgn op mt lhs e
            DTInstance _ args -> Subroutine (lhsToExpr lhs) (instanceToArgs args)
            _ -> error $ "invalid block item decl or stmt: " ++ (show tokens)
        maybeLhs = takeLHS $ init tokens
        Just lhs = maybeLhs
        isStmt :: DeclToken -> Bool
        isStmt (DTAsgn{}) = True
        isStmt (DTInstance{}) = True
        isStmt _ = False

traceStmt :: Position -> Stmt
traceStmt pos = CommentStmt $ "Trace: " ++ show pos

-- converts port bindings to call args
instanceToArgs :: [PortBinding] -> Args
instanceToArgs bindings =
    Args pnArgs kwArgs
    where
        (pnBindings, kwBindings) = partition (null . fst) bindings
        pnArgs = map snd pnBindings
        kwArgs = kwBindings

-- [PUBLIC]: parser for comma-separated declarations or assignment lists; this
-- is only used for `for` loop initialization lists
parseDTsAsDeclsOrAsgns :: [DeclToken] -> Either [Decl] [(LHS, Expr)]
parseDTsAsDeclsOrAsgns tokens =
    forbidNonEqAsgn tokens $
    if hasLeadingAsgn || tripLookahead tokens
        then Right $ parseDTsAsAsgns tokens
        else Left  $ parseDTsAsDecls tokens
    where
        hasLeadingAsgn =
            -- if there is an asgn token before the next comma
            case (findIndex isComma tokens, findIndex isAsgnToken tokens) of
                (Just a, Just b) -> a > b
                (Nothing, Just _) -> True
                _ -> False

-- internal parser for basic assignment lists
parseDTsAsAsgns :: [DeclToken] -> [(LHS, Expr)]
parseDTsAsAsgns tokens =
    case l1 of
        [] -> [asgn]
        DTComma{} : remaining -> asgn : parseDTsAsAsgns remaining
        _ -> error $ "bad assignment tokens: " ++ show tokens
    where
        (lhsToks, l0) = break isDTAsgn tokens
        lhs = case takeLHS lhsToks of
            Nothing -> error $ "could not parse as LHS: " ++ show lhsToks
            Just l -> l
        DTAsgn _ AsgnOpEq Nothing expr : l1 = l0
        asgn = (lhs, expr)

        isDTAsgn :: DeclToken -> Bool
        isDTAsgn (DTAsgn _ _ Nothing _) = True
        isDTAsgn _ = False

isAsgnToken :: DeclToken -> Bool
isAsgnToken (DTBit{}   ) = True
isAsgnToken (DTConcat{}) = True
isAsgnToken (DTStream{}) = True
isAsgnToken (DTDot{}   ) = True
isAsgnToken (DTAsgn _ op _ _) = op /= AsgnOpEq
isAsgnToken _ = False

takeLHS :: [DeclToken] -> Maybe LHS
takeLHS [] = Nothing
takeLHS (t : ts) =
    foldl takeLHSStep (takeLHSStart t) ts

takeLHSStart :: DeclToken -> Maybe LHS
takeLHSStart (DTConcat _     lhss) = Just $ LHSConcat lhss
takeLHSStart (DTStream _ o e lhss) = Just $ LHSStream o e lhss
takeLHSStart (DTIdent  _ x       ) = Just $ LHSIdent x
takeLHSStart _ = Nothing

takeLHSStep :: Maybe LHS -> DeclToken -> Maybe LHS
takeLHSStep (Just curr) (DTBit   _  e   ) = Just $ LHSBit   curr e
takeLHSStep (Just curr) (DTRange _ (m,r)) = Just $ LHSRange curr m r
takeLHSStep (Just curr) (DTDot   _  x   ) = Just $ LHSDot curr x
takeLHSStep _ _ = Nothing


-- batches together separate declaration lists
type Triplet = (Identifier, [Range], Maybe Expr)
type Component = (Direction, Type, [Triplet])
finalize :: (Position, Component) -> [Decl]
finalize (pos, (dir, typ, trips)) =
    CommentDecl ("Trace: " ++ show pos) :
    map (\(x, a, me) -> Variable dir typ x a me) trips


-- internal; entrypoint of the critical portion of our parser
parseDTsAsComponents :: [DeclToken] -> [(Position, Component)]
parseDTsAsComponents [] = []
parseDTsAsComponents tokens =
    (position, component) : parseDTsAsComponents tokens'
    where
        (position, component, tokens') = parseDTsAsComponent tokens

parseDTsAsComponent :: [DeclToken] -> (Position, Component, [DeclToken])
parseDTsAsComponent [] = error "parseDTsAsComponent unexpected end of tokens"
parseDTsAsComponent l0 =
    if l /= Nothing && l /= Just Automatic
        then error $ "unexpected non-automatic lifetime: " ++ show l0
        else (position, component, l5)
    where
        (dir, l1) = takeDir      l0
        (l  , l2) = takeLifetime l1
        (tf , l3) = takeType     l2
        (rs , l4) = takeRanges   l3
        (tps, l5) = takeTrips    l4 True
        component = (dir, tf rs, tps)
        position = tokPos $ head l0

takeTrips :: [DeclToken] -> Bool -> ([Triplet], [DeclToken])
takeTrips [] True = error "incomplete declaration"
takeTrips [] False = ([], [])
takeTrips l0 force =
    if not force && not (tripLookahead l0)
        then ([], l0)
        else (trip : trips, l5)
    where
        (x , l1) = takeIdent  l0
        (a , l2) = takeRanges l1
        (me, l3) = takeAsgn   l2
        (_ , l4) = takeComma  l3
        trip = (x, a, me)
        (trips, l5) = takeTrips l4 False

tripLookahead :: [DeclToken] -> Bool
tripLookahead [] = False
tripLookahead l0 =
    -- every triplet *must* begin with an identifier
    if not (isIdent $ head l0) then
        False
    -- if the identifier is the last token, or if it assigned a value, then we
    -- know we must have a valid triplet ahead
    else if null l1 || asgn /= Nothing then
        True
    -- if there is an ident followed by some number of ranges, and that's it,
    -- then there is a trailing declaration of an array ahead
    else if (not $ null l1) && (null l2) then
        True
    -- if there is a comma after the identifier (and optional ranges and
    -- assignment) that we're looking at, then we know this identifier is not a
    -- type name, as type names must be followed by a first identifier before a
    -- comma or the end of the list
    else
        (not $ null l3) && (isComma $ head l3)
    where
        (_   , l1) = takeIdent  l0
        (_   , l2) = takeRanges l1
        (asgn, l3) = takeAsgn   l2

takeDir :: [DeclToken] -> (Direction, [DeclToken])
takeDir (DTDir _ dir : rest) = (dir  , rest)
takeDir                rest  = (Local, rest)

takeLifetime :: [DeclToken] -> (Maybe Lifetime, [DeclToken])
takeLifetime (DTLifetime _ l : rest) = (Just  l, rest)
takeLifetime                   rest  = (Nothing, rest)

takeType :: [DeclToken] -> ([Range] -> Type, [DeclToken])
takeType (DTIdent _ a  : DTDot _ b      : rest) = (InterfaceT a (Just b), rest)
takeType (DTType  _ tf : DTSigning _ sg : rest) = (tf       sg          , rest)
takeType (DTType  _ tf                  : rest) = (tf       Unspecified , rest)
takeType (DTSigning _ sg                : rest) = (Implicit sg          , rest)
takeType (DTPSIdent _ ps tn             : rest) = (Alias (Just ps) tn   , rest)
takeType (DTIdent pos tn                : rest) =
    if couldBeTypename
        then (Alias (Nothing) tn  ,                  rest)
        else (Implicit Unspecified, DTIdent pos tn : rest)
    where
        couldBeTypename =
            case (findIndex isIdent rest, findIndex isComma rest) of
                -- no identifiers left => no decl asgns
                (Nothing, _) -> False
                -- an identifier is left, and no more commas
                (_, Nothing) -> True
                -- if comma is first, then this ident is a declaration
                (Just a, Just b) -> a < b
takeType rest = (Implicit Unspecified, rest)

takeRanges :: [DeclToken] -> ([Range], [DeclToken])
takeRanges [] = ([], [])
takeRanges (token : tokens) =
    case token of
        DTRange _ (NonIndexed, r) -> (r         : rs, rest          )
        DTBit   _ s               -> (asRange s : rs, rest          )
        DTAutoDim _               ->
            case rest of
                (DTAsgn _ AsgnOpEq Nothing (Pattern l) : _) -> autoDim l
                (DTAsgn _ AsgnOpEq Nothing (Concat  l) : _) -> autoDim l
                _ ->                 ([]            , token : tokens)
        _                         -> ([]            , token : tokens)
    where
        (rs, rest) = takeRanges tokens
        asRange s = (Number "0", BinOp Sub s (Number "1"))
        autoDim :: [a] -> ([Range], [DeclToken])
        autoDim l =
            ((lo, hi) : rs, rest)
            where
                n = length l
                lo = Number "0"
                hi = Number $ show (n - 1)

-- Matching `AsgnOpEq` and `AsgnOpNonBlocking` here allows tripLookahead to work
-- both for standard declarations and in `parseDTsAsDeclOrStmt`, where we're
-- checking for an assignment statement. The other entry points disallow
-- `AsgnOpNonBlocking`, so this doesn't liberalize the parser.
takeAsgn :: [DeclToken] -> (Maybe Expr, [DeclToken])
takeAsgn (DTAsgn _ op Nothing e : rest) =
    if op == AsgnOpEq || op == AsgnOpNonBlocking
        then (Just e , rest)
        else (Nothing, rest)
takeAsgn rest = (Nothing, rest)

takeComma :: [DeclToken] -> (Bool, [DeclToken])
takeComma [] = (False, [])
takeComma (DTComma{} : rest) = (True, rest)
takeComma toks = error $ "expected comma or end of decl, got: " ++ show toks

takeIdent :: [DeclToken] -> (Identifier, [DeclToken])
takeIdent (DTIdent _ x : rest) = (x, rest)
takeIdent tokens = error $ "takeIdent didn't find identifier: " ++ show tokens


isIdent :: DeclToken -> Bool
isIdent (DTIdent{}) = True
isIdent _ = False

isComma :: DeclToken -> Bool
isComma (DTComma{}) = True
isComma _ = False

tokPos :: DeclToken -> Position
tokPos (DTComma    p) = p
tokPos (DTAutoDim  p) = p
tokPos (DTAsgn     p _ _ _) = p
tokPos (DTRange    p _) = p
tokPos (DTIdent    p _) = p
tokPos (DTPSIdent  p _ _) = p
tokPos (DTDir      p _) = p
tokPos (DTType     p _) = p
tokPos (DTParams   p _) = p
tokPos (DTInstance p _) = p
tokPos (DTBit      p _) = p
tokPos (DTConcat   p _) = p
tokPos (DTStream   p _ _ _) = p
tokPos (DTDot      p _) = p
tokPos (DTSigning  p _) = p
tokPos (DTLifetime p _) = p
