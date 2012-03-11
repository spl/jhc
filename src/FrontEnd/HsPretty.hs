-----------------------------------------------------------------------------
--  $Id: HsPretty.hs,v 1.10 2001/12/17 03:38:54 bjpop Exp $
--
-- (c) The GHC Team, Noel Winstanley 1997-2000
--
-- Pretty printer for Haskell.
--
-----------------------------------------------------------------------------

module FrontEnd.HsPretty (PPLayout(..),PPHsMode(..),
		render,
		ppHsModule,
		ppHsDecl,
		ppHsDecls,
		ppHsExp,
                ppHsStmt,
                ppHsPat,
                ppHsAlt,
                ppGAlt,
                ppHsGuardedRhs
		) where

import Data.Char
import qualified Text.PrettyPrint.HughesPJ as P

import Doc.DocLike(TextLike(..),DocLike(..))
import Doc.PPrint(pprint)
import FlagDump as FD
import FrontEnd.HsSyn
import FrontEnd.Rename(unRename)
import FrontEnd.SrcLoc(Located(..))
import Name.Name
import Name.Names
import Options
import qualified Doc.DocLike as DL
import qualified Doc.PPrint as P

infixl 5 $$$

-----------------------------------------------------------------------------
-- pretty printing monad

data PPLayout = PPOffsideRule		-- classical layout
	      | PPSemiColon		-- classical layout made explicit
	      | PPInLine		-- inline decls, \n between them
	      | PPNoLayout		-- everything on a single line
	      deriving Eq

type Indent = Int

data PPHsMode = PPHsMode {
			 classIndent,  -- class, instance
			 doIndent,
			 caseIndent,
			 letIndent,
			 whereIndent :: Indent,
			 onsideIndent :: Indent,
			 spacing :: Bool, -- blank lines between statements?
			 layout :: PPLayout,   -- to do
			 comments :: Bool -- to come later
			 }

defaultMode = PPHsMode{
		      classIndent = 8,
		      doIndent = 3,
		      caseIndent = 4,
		      letIndent = 4,
		      whereIndent = 6,
		      onsideIndent = 2,
		      spacing = True,
		      layout = PPOffsideRule,
		      comments = True
		      }

newtype DocM s a = DocM (s -> a)

instance Functor (DocM s) where
	 fmap f xs = do x <- xs; return (f x)

instance Monad (DocM s) where
	(>>=) = thenDocM
	(>>) = then_DocM
	return = retDocM

{-# INLINE thenDocM #-}
{-# INLINE then_DocM #-}
{-# INLINE retDocM #-}
{-# INLINE unDocM #-}
{-# INLINE getPPEnv #-}
thenDocM m k = DocM $ (\s -> case unDocM m $ s of a -> unDocM (k a) $ s)
then_DocM m k = DocM $ (\s ->case unDocM m $ s of a ->  unDocM k $ s)
retDocM a = DocM (\s -> a)
unDocM :: DocM s a -> (s -> a)
unDocM (DocM f) = f

-- all this extra stuff, just for this one function..
getPPEnv :: DocM s s
getPPEnv = DocM id

-- So that pp code still looks the same
-- this means we lose some generality though
type Doc = DocM PPHsMode P.Doc

-- The pretty printing combinators

nest :: Int -> Doc -> Doc
nest i m = m >>= return . P.nest i

dropAs (HsAsPat _ e) = e
dropAs e = e

-- Literals
instance DL.TextLike Doc where
    empty = return P.empty
    text = return . P.text
    char = return . P.char

int :: Int -> Doc
int = return . P.int

integer :: Integer -> Doc
integer = return . P.integer

float :: Float -> Doc
float = return . P.float

double :: Double -> Doc
double = return . P.double

-- Simple Combining Forms

parens, brackets, braces :: Doc -> Doc
parens d = d >>= return . P.parens
parenszh d = d >>= \d' -> return $ P.text "(# " P.<> d' P.<> P.text " #)"

brackets d = d >>= return . P.brackets
braces d = d >>= return . P.braces

-- Constants

semi,comma,equals :: Doc
semi = return P.semi
comma = return P.comma
equals = return P.equals

-- Combinators
--
instance DocLike Doc where
    aM <> bM = do{a<-aM;b<-bM;return (a P.<> b)}
    aM <+> bM = do{a<-aM;b<-bM;return (a P.<+> b)}
    aM <$> bM = do{a<-aM;b<-bM;return (a P.$$ b)}
    hcat dl = sequence dl >>= return . P.hcat
    hsep dl = sequence dl >>= return . P.hsep
    vcat dl = sequence dl >>= return . P.vcat

($$) :: Doc -> Doc -> Doc
aM $$ bM = do{a<-aM;b<-bM;return (a P.$$ b)}

fsep :: [Doc] -> Doc
fsep dl = sequence dl >>= return . P.fsep

-- Yuk, had to cut-n-paste this one from Pretty.hs
punctuate :: Doc -> [Doc] -> [Doc]
punctuate p []     = []
punctuate p (d:ds) = go d ds
                   where
                     go d [] = [d]
                     go d (e:es) = (d <> p) : go e es

-- this is the equivalent of runM now.
renderWithMode :: PPHsMode -> Doc -> String
renderWithMode ppMode d = P.render . unDocM d $ ppMode

render :: Doc -> String
render = renderWithMode defaultMode

-------------------------  Pretty-Print a Module --------------------
ppHsModule :: HsModule -> Doc
ppHsModule (HsModule mod _ mbExports imp decls _ _) =
   topLevel (ppHsModuleHeader mod mbExports)
            (map ppHsImportDecl imp ++ map ppHsDecl decls)

ppHsDecls :: [HsDecl] -> Doc
ppHsDecls ds = vcat $ map ppHsDecl ds

--------------------------  Module Header ------------------------------
ppHsModuleHeader :: Module -> Maybe [HsExportSpec] ->  Doc
ppHsModuleHeader (Module modName) mbExportList = mySep [
		 text "module",
		 text $ show modName,
		 maybePP (parenList . map ppHsExportSpec) mbExportList,
		 text "where"]

ppHsExportSpec :: HsExportSpec -> Doc
ppHsExportSpec e = f e where
    f (HsEVar name)                     = ppHsQNameParen name
    f (HsEAbs name)                     = ppHsQName name
    f (HsEThingAll name)                = ppHsQName name <> text"(..)"
    f (HsEThingWith name nameList)      = ppHsQName name <> (parenList . map ppHsQNameParen $ nameList)
    f (HsEModuleContents (show -> name)) = text "module" <+> text name
    f (HsEQualified ClassName e)         = text "class" <+> ppHsExportSpec e
    f (HsEQualified SortName e)          = text "kind" <+> ppHsExportSpec e
    f (HsEQualified TypeConstructor e)   = text "type" <+> ppHsExportSpec e
    f (HsEQualified DataConstructor e)   = text "data" <+> ppHsExportSpec e
    f (HsEQualified n e)                 = tshow n <+> ppHsExportSpec e

tshow = text . show
ppHsImportDecl (HsImportDecl pos (show -> mod) bool mbName mbSpecs) =
	   mySep [text "import",
		 if bool then text "qualified" else empty,
		 text mod,
		 maybePP (\(show -> n) -> text "as" <+> text n) mbName,
		 maybePP exports mbSpecs]
           where
	   exports (b,specList)
	    | b = text "hiding" <+> (parenList . map ppHsExportSpec $ specList)
	    | otherwise = parenList . map ppHsExportSpec $  specList

ppHsTName (n,Nothing) = ppHsName n
ppHsTName (n,Just t) = parens (ppHsName n <+> text "::" <+> ppHsType t)

-------------------------  Declarations ------------------------------
ppHsRule prules@HsRule {} = text (show (hsRuleString prules)) <+> text "forall" <+> vars <+> text "." $$ nest 4 rest  where
    vars = hsep (map ppHsTName $ hsRuleFreeVars prules)
    rest = ppHsExp (hsRuleLeftExpr prules) <+> text "=" <+> ppHsExp (hsRuleRightExpr prules)

ppClassHead :: HsClassHead -> Doc
ppClassHead (HsClassHead c n ts) = ans c where
    ans [] = f n ts
    ans c = ppHsContext c <+> text "=>" <+> f n ts
    f n ts = ppHsType (foldl HsTyApp (HsTyCon n)  ts)

ppHsDecl :: HsDecl -> Doc
ppHsDecl (HsActionDecl _ p e) = ppHsPat p <+> text "<-" <+> ppHsExp e
ppHsDecl (HsDeclDeriving _ e) = text "derive instance" <+> ppClassHead e
ppHsDecl (HsPragmaRules rs@(HsRule { hsRuleIsMeta = False }:_)) = text "{-# RULES" $$ nest 4 (myVcat (map ppHsRule rs)) $$ text "#-}"
ppHsDecl (HsPragmaRules rs@(HsRule { hsRuleIsMeta = True }:_)) = text "{-# METARULES" $$ nest 4 (myVcat (map ppHsRule rs)) $$ text "#-}"
--ppHsDecl prules@HsPragmaRules {} = text ("{-# RULES " ++ show (hsDeclString prules)) <+> text "forall" <+> vars <+> text "." $$ nest 4 rest $$ text "#-}" where
--    vars = hsep (map ppHsTName $ hsDeclFreeVars prules)
--    rest = ppHsExp (hsDeclLeftExpr prules) <+> text "=" <+> ppHsExp (hsDeclRightExpr prules)
ppHsDecl prules@HsPragmaSpecialize {} = text "{-# SPECIALIZE ... #-}" --  ++ show (hsDeclString prules)) <+> text "forall" <+> vars <+> text "." $$ nest 4 rest $$ text "#-}" where
--    vars = hsep (map ppHsTName $ hsDeclFreeVars prules)
--    rest = ppHsExp (hsDeclLeftExpr prules) <+> text "=" <+> ppHsExp (hsDeclRightExpr prules)
ppHsDecl fd@(HsForeignDecl _ _ n qt) = text "ForeignDecl" <+> ppHsName n <+> ppHsQualType qt <+> text (show fd)
ppHsDecl fd@(HsForeignExport _ _ n qt) = text "ForeignExport" <+> ppHsName n <+> ppHsQualType qt <+> text (show fd)
ppHsDecl (HsTypeDecl loc name nameList htype) =
	   --blankline $
	   mySep ( [text "type",ppHsName name]
		   ++ map ppHsType nameList
		   ++ [equals, ppHsType htype])

ppHsDecl HsDataDecl { .. } = ans where
    ans = mySep ([declType, ppHsContext hsDeclContext, ppHsName hsDeclName]
                  ++ map ppHsName hsDeclArgs)
                  <+> (myVcat (zipWith (<+>) (equals : repeat (char '|'))
                                           (map ppHsConstr hsDeclCons))
                       $$$ ppHsDeriving hsDeclDerives)
    declType = case hsDeclDeclType of
        DeclTypeKind    -> text "data kind"
        DeclTypeData    -> text "data"
        DeclTypeNewtype -> text "newtype"

-- special case for empty class declaration
ppHsDecl (HsClassDecl pos qualType []) =
	   --blankline $
	   mySep [text "class", ppClassHead qualType]
ppHsDecl (HsClassDecl pos qualType declList) =
	   --blankline $
	   mySep [text "class", ppClassHead qualType, text "where"]
	   $$$ body classIndent (map ppHsDecl declList)

ppHsDecl (HsClassAliasDecl pos name args context classes declList) =
	   --blankline $
	   mySep ([text "class alias", ppHsName name] ++ map ppHsType args
                  ++ [equals, ppHsContext context, text "=>", ppHsContext classes, text "where"])
	   $$$ body classIndent (map ppHsDecl declList)

-- m{spacing=False}
-- special case for empty instance declaration
ppHsDecl (HsInstDecl pos qualType []) =
	   --blankline $
	   mySep [text "instance", ppClassHead qualType]
ppHsDecl (HsInstDecl pos qualType declList) =
	   --blankline $
	   mySep [text "instance", ppClassHead qualType, text "where"]
	   $$$ body classIndent (map ppHsDecl declList)

ppHsDecl (HsDefaultDecl pos htype) =
	   --blankline $
	   text "default" <+> ppHsType htype

ppHsDecl (HsTypeSig pos nameList qualType) =
	 --blankline $
	 mySep ((punctuate comma . map ppHsNameParen $ nameList)
	       ++ [text "::", ppHsQualType qualType])

{-
ppHsDecl (HsFunBind pos matches)
   = foldr ($$$) empty (map ppMatch matches)
-}
ppHsDecl (HsFunBind matches)
   =  foldr ($$$) empty (map ppMatch matches)

ppHsDecl (HsPatBind pos pat rhs whereDecls)
   = myFsep [ppHsPatOrOp pat, ppHsRhs rhs] $$$ ppWhere whereDecls
    where
	-- special case for single operators
	ppHsPatOrOp (HsPVar n) = ppHsNameParen n
	ppHsPatOrOp p = ppHsPat p

ppHsDecl (HsInfixDecl pos assoc prec nameList) =
	   --blankline $
	   mySep ([ppAssoc assoc, int prec]
	     ++ (punctuate comma . map ppHsNameInfix $ nameList))
	    where
	    ppAssoc HsAssocNone  = text "infix"
	    ppAssoc HsAssocLeft  = text "infixl"
	    ppAssoc HsAssocRight = text "infixr"
ppHsDecl (HsPragmaProps _ w ns) = text "{-# " <> text w <+> mySep (punctuate comma . map ppHsNameParen $ ns) <+> text "#-}"
ppHsDecl _ = error "ppHsDecl: unknown construct"

ppMatch (HsMatch pos f ps rhs whereDecls)
   =   myFsep (ppHsQNameParen f : map ppHsPat ps ++ [ppHsRhs rhs])
   $$$ ppWhere whereDecls

ppWhere [] = empty
ppWhere l = nest 2 (text "where" $$$ body whereIndent (map ppHsDecl l))

------------------------- Data & Newtype Bodies -------------------------
mprintExists :: HsConDecl -> Doc
mprintExists hcd = case hsConDeclExists hcd of
    [] -> empty
    vs -> text "exists" <+> hsep (map (return . pprint) vs) <+> char '.'

ppHsConstr :: HsConDecl -> Doc
ppHsConstr cd@HsRecDecl { hsConDeclName = name, hsConDeclRecArg = fieldList } =
	 mprintExists cd <+> ppHsName name
	 <> (braceList . map ppField $ fieldList)
ppHsConstr cd@HsConDecl { hsConDeclName = name, hsConDeclConArg = typeList}
     | isSymbolName name && length typeList == 2 =
	 let [l, r] = typeList in
	 mprintExists cd <+> myFsep [ppHsBangType l, ppHsName name, ppHsBangType r]
     | otherwise = mprintExists cd <+> (mySep $ (ppHsName name) :
		 map ppHsBangType typeList)

ppField :: ([HsName],HsBangType) -> Doc
ppField (names, ty) = myFsepSimple $  (punctuate comma . map ppHsName $ names) ++
			      [text "::", ppHsBangType ty]

ppHsBangType :: HsBangType -> Doc
ppHsBangType (HsBangedTy ty) = char '!' <> ppHsTypeArg ty
ppHsBangType (HsUnBangedTy ty) = ppHsTypeArg ty

ppHsDeriving :: [HsName] -> Doc
ppHsDeriving []  = empty
ppHsDeriving [d] = text "deriving" <+> ppHsQName d
ppHsDeriving ds  = text "deriving" <+> parenList (map ppHsQName ds)

------------------------- Types -------------------------
ppHsQualType :: HsQualType -> Doc
ppHsQualType (HsQualType [] htype) = ppHsType htype
ppHsQualType (HsQualType context htype) = -- if it's HsQualType, context is never empty
	     myFsep [ ppHsContext context, text "=>", ppHsType htype]

parensIf :: Bool -> Doc -> Doc
parensIf True = parens
parensIf False = id

instance P.PPrint Doc HsType where
    pprint = ppHsType

ppHsType :: HsType -> Doc
ppHsType = ppHsTypePrec 0

ppHsTypeArg :: HsType -> Doc
ppHsTypeArg = ppHsTypePrec 2

-- precedences:
-- 0: top level
-- 1: left argument of ->
-- 2: argument of constructor

ppHsTypePrec :: Int -> HsType -> Doc
ppHsTypePrec p (HsTyFun a b) =
	parensIf (p > 0) $
		myFsep [ppHsTypePrec 1 a, text "->", ppHsType b]
ppHsTypePrec p (HsTyAssoc) = text "<assoc>"
ppHsTypePrec p (HsTyEq a b) =
	parensIf (p > 0) $ myFsep [ppHsType a, text "=", ppHsType b]
ppHsTypePrec p (HsTyTuple l) = parenList . map ppHsType $ l
ppHsTypePrec p (HsTyUnboxedTuple l) = parenListzh . map ppHsType $ l
-- special case
ppHsTypePrec p (HsTyApp (HsTyCon lcons) b ) | lcons == nameName tc_List = brackets $ ppHsType b
ppHsTypePrec p (HsTyApp a b) =
	parensIf (p > 1) $ myFsep[ppHsType a, ppHsTypeArg b]
ppHsTypePrec p (HsTyVar name) = ppHsName name
-- special case
ppHsTypePrec p (HsTyCon name) = ppHsQName name
ppHsTypePrec p HsTyForall { hsTypeVars = vs, hsTypeType = qt } = parensIf (p > 1) $ do
    pp <- ppHsQualType qt
    return $ DL.text "forall" DL.<+> DL.hsep (map pprint vs) DL.<+> DL.char '.' DL.<+> pp
ppHsTypePrec p HsTyExists { hsTypeVars = vs, hsTypeType = qt } = parensIf (p > 1) $ do
    pp <- ppHsQualType qt
    return $ DL.text "exists" DL.<+> DL.hsep (map pprint vs) DL.<+> DL.char '.' DL.<+> pp
ppHsTypePrec _ HsTyExpKind { hsTyLType = Located _ t, hsTyKind = k } = do
    t <- ppHsType t
    return $ DL.parens ( t DL.<+> DL.text "::" DL.<+> pprint k)

instance DL.DocLike d => P.PPrint d HsKind where
    pprint (HsKind k) = pprint k
    pprint (HsKindFn (HsKind k) t) = pprint k DL.<+> DL.text "->" DL.<+> pprint t
    pprint (HsKindFn a b) = DL.parens (pprint a) DL.<+> DL.text "->" DL.<+> pprint b

------------------------- Expressions -------------------------
ppHsRhs :: HsRhs -> Doc
ppHsRhs (HsUnGuardedRhs exp) = equals <+> ppHsExp exp
ppHsRhs (HsGuardedRhss guardList) =
	myVcat . map ppHsGuardedRhs $ guardList

ppHsGuardedRhs :: HsGuardedRhs -> Doc
ppHsGuardedRhs (HsGuardedRhs pos guard body) =
	       myFsep [ char '|',
		      ppHsExp guard,
		      equals,
		      ppHsExp body]

{-# NOINLINE ppHsLit #-}
ppHsLit :: HsLiteral -> Doc
ppHsLit	(HsInt i)      = integer i
ppHsLit	(HsChar c)     = text (show c)
ppHsLit	(HsString s)   = text (show s)
ppHsLit	(HsFrac r)     = double (fromRational r)
-- GHC unboxed literals:
ppHsLit (HsCharPrim c)   = text (show c)           <> char '#'
ppHsLit (HsStringPrim s) = text (show s)           <> char '#'
ppHsLit (HsIntPrim i)    = integer i               <> char '#'
ppHsLit (HsFloatPrim r)  = float  (fromRational r) <> char '#'
ppHsLit (HsDoublePrim r) = double (fromRational r) <> text "##"
-- GHC extension:
ppHsLit (HsLitLit s)     = text "''" <> text s <> text "''"

{-# NOINLINE ppHsExp #-}
ppHsExp :: HsExp -> Doc
ppHsExp (HsLit l) = ppHsLit l
-- lambda stuff
ppHsExp (HsInfixApp a op b) = myFsep[ppHsExp a, ppInfix op, ppHsExp b]
	where
	ppInfix (HsAsPat as (HsVar n)) | dump FD.Aspats = ppHsName as <> char '@' <> ppHsQNameInfix n
	ppInfix (HsAsPat _ (HsVar n)) = ppHsQNameInfix n
	ppInfix (HsAsPat as (HsCon n)) | dump FD.Aspats = ppHsName as <> char '@' <> ppHsQNameInfix n
	ppInfix (HsAsPat _ (HsCon n)) = ppHsQNameInfix n
	ppInfix (HsVar n) = ppHsQNameInfix n
	ppInfix (HsCon n) = ppHsQNameInfix n
	ppInfix n = error $ "illegal infix expression: " ++ show n
ppHsExp (HsNegApp e) = myFsep [char '-', ppHsExp e]
ppHsExp (HsApp a b) = myFsep [ppHsExp a, ppHsExp b]
ppHsExp HsError { hsExpString = msg } = text $ "<error:" ++ msg ++ ">"
-- ppHsExp (HsLambda expList body) = myFsep $
ppHsExp (HsLambda _srcLoc expList body) = myFsep $              -- srcLoc added by Bernie
	(((char '\\' ):) . map ppHsPat $ expList)
	++ [text "->", ppHsExp body]
-- keywords
ppHsExp (HsLet expList letBody) =
	myFsep [text "let" <+> body letIndent (map ppHsDecl expList),
		text "in", ppHsExp letBody]
ppHsExp (HsIf cond thenexp elsexp) =
	myFsep [text "if", ppHsExp cond,
	      text "then", ppHsExp thenexp,
	      text "else", ppHsExp elsexp]
ppHsExp (HsCase cond altList) = myFsep[text "case", ppHsExp cond, text "of"]
			        $$$ body caseIndent (map ppHsAlt altList)
ppHsExp (HsDo stmtList) = text "do" $$$ body doIndent (map ppHsStmt stmtList)
-- Constructors & Vars
ppHsExp (HsVar name ) = ppHsQNameParen name
ppHsExp (HsCon name) = ppHsQNameParen name
ppHsExp (HsTuple expList) = parenList . map ppHsExp $ expList
ppHsExp (HsUnboxedTuple expList) = parenListzh . map ppHsExp $ expList
-- weird stuff
ppHsExp (HsParen exp) = parens . ppHsExp $ exp
ppHsExp (HsLeftSection v exp)   | (HsVar name) <- dropAs v =
	parens (ppHsExp exp <+> ppHsQNameInfix name)
ppHsExp (HsLeftSection v exp)   | (HsCon name) <- dropAs v =
	parens (ppHsExp exp <+> ppHsQNameInfix name)
ppHsExp (HsLeftSection _ _) = error "illegal left section"
ppHsExp (HsRightSection exp v) | (HsVar name) <- dropAs v =
	parens (ppHsQNameInfix name <+> ppHsExp exp)
ppHsExp (HsRightSection exp v) | (HsCon name) <- dropAs v =
	parens (ppHsQNameInfix name <+> ppHsExp exp)
ppHsExp (HsRightSection _ _) = error "illegal right section"
ppHsExp (HsRecConstr c fieldList) =
	ppHsQName c
        <> (braceList . map ppHsFieldUpdate  $ fieldList)
ppHsExp (HsRecUpdate exp fieldList) =
	ppHsExp exp
        <> (braceList . map ppHsFieldUpdate  $ fieldList)
-- patterns
-- special case that would otherwise be buggy
ppHsExp (HsAsPat _ p) | not (dump FD.Aspats) = ppHsExp p
ppHsExp (HsAsPat name (HsIrrPat (Located _ exp))) =
	myFsep[ppHsName name <> char '@', char '~' <> ppHsExp exp]
ppHsExp (HsAsPat name exp) = hcat[ppHsName name,char '@',ppHsExp exp]
ppHsExp (HsWildCard _) = char '_'
ppHsExp (HsIrrPat (Located _ exp)) = char '~' <> ppHsExp exp
ppHsExp (HsBangPat (Located _ exp)) = char '!' <> ppHsExp exp
-- Lists
ppHsExp (HsList list) =
	bracketList . punctuate comma . map ppHsExp $ list
ppHsExp (HsEnumFrom exp) =
	bracketList [ppHsExp exp,text ".."]
ppHsExp (HsEnumFromTo from to) =
	bracketList [ppHsExp from, text "..", ppHsExp to]
ppHsExp (HsEnumFromThen from thenE) =
	bracketList [ppHsExp from <> comma, ppHsExp thenE]
ppHsExp (HsEnumFromThenTo from thenE to) =
	bracketList [ppHsExp from <> comma, ppHsExp thenE,
			text "..", ppHsExp to]
ppHsExp (HsListComp exp stmtList) =
	bracketList ([ppHsExp exp, char '|']
		++ (punctuate comma . map ppHsStmt $ stmtList))
ppHsExp (HsExpTypeSig pos exp ty) =
	myFsep[ppHsExp exp, text "::", ppHsQualType ty]
ppHsExp (HsLocatedExp (Located _ x)) = ppHsExp x

------------------------- Patterns -----------------------------

ppHsPat :: HsPat -> Doc
ppHsPat (HsPVar name) = ppHsNameParen name
ppHsPat (HsPLit lit) = ppHsLit lit
ppHsPat (HsPNeg p) = myFsep [char '-', ppHsPat p]
ppHsPat (HsPInfixApp a op b) = myFsep[ppHsPat a, ppHsQNameInfix op, ppHsPat b]
ppHsPat (HsPApp n ps) = myFsep (ppHsQName n : map ppHsPat ps)
ppHsPat (HsPTuple ps) = parenList . map ppHsPat $ ps
ppHsPat (HsPUnboxedTuple ps) = parenListzh . map ppHsPat $ ps
ppHsPat (HsPList ps) = bracketList . punctuate comma . map ppHsPat $ ps
ppHsPat (HsPParen p) = parens . ppHsPat $ p
ppHsPat (HsPRec c fields)
    =  ppHsQName c
    <> (braceList . map ppHsPatField $ fields)
-- special case that would otherwise be buggy
ppHsPat (HsPAsPat name (HsPIrrPat (Located _ pat))) =
	myFsep[ppHsName name <> char '@', char '~' <> ppHsPat pat]
ppHsPat	(HsPAsPat name pat) = hcat[ppHsName name,char '@',ppHsPat pat]
ppHsPat	HsPWildCard = char '_'
ppHsPat	(HsPIrrPat (Located _ pat)) = char '~' <> ppHsPat pat
ppHsPat	~(HsPBangPat (Located _ pat)) = char '!' <> ppHsPat pat

ppHsPatField (HsPFieldPat name pat) = myFsep[ppHsQName name, equals, ppHsPat pat]

------------------------- Case bodies  -------------------------
ppHsAlt :: HsAlt -> Doc
ppHsAlt (HsAlt pos exp gAlts decls) =
	ppHsPat exp <+> ppGAlts gAlts $$$ ppWhere decls

ppGAlts :: HsRhs -> Doc
ppGAlts (HsUnGuardedRhs exp) = text "->" <+> ppHsExp exp
ppGAlts (HsGuardedRhss altList) = myVcat . map ppGAlt $ altList

ppGAlt (HsGuardedRhs pos exp body) =
	 myFsep [char '|', ppHsExp exp, text "->", ppHsExp body]

------------------------- Statements in monads & list comprehensions -----
ppHsStmt :: HsStmt -> Doc
ppHsStmt (HsGenerator _sloc exp from) =                    -- sloc added by Bernie
	 ppHsPat exp <+> text "<-" <+> ppHsExp from
ppHsStmt (HsQualifier exp) = ppHsExp exp
ppHsStmt (HsLetStmt declList) = text "let"
				$$$ body letIndent (map ppHsDecl declList)

------------------------- Record updates
ppHsFieldUpdate :: HsFieldUpdate -> Doc
ppHsFieldUpdate (HsFieldUpdate name exp) =
		  myFsep[ppHsQName name,equals,ppHsExp exp]

------------------------- Names -------------------------
ppHsQName :: HsName -> Doc
ppHsQName n = text $ show n
--ppHsQName (UnQual name)			= ppHsIdentifier name
--ppHsQName z@(Qual m@(Module mod) name)
--	 | otherwise = text mod <> char '.' <> ppHsIdentifier name

ppHsName = ppHsQName

ppHsQNameParen :: HsName -> Doc
ppHsQNameParen name = parensIf (isSymbolName name) (ppHsQName name)

ppHsQNameInfix :: HsName -> Doc
ppHsQNameInfix name
	| isSymbolName name = ppHsQName name
	| otherwise = char '`' <> ppHsQName name <> char '`'

--ppHsIdentifier :: HsIdentifier -> Doc
--ppHsIdentifier name = text (show name)

ppHsNameParen :: HsName -> Doc
ppHsNameParen name = parensIf (isSymbolName name) (ppHsName name)

ppHsNameInfix :: HsName -> Doc
ppHsNameInfix name
	| isSymbolName name = ppHsName name
	| otherwise = char '`' <> ppHsName name <> char '`'

isSymbolName :: HsName -> Bool
--isSymbolName (Qual _ (HsSymbol _)) = True
--isSymbolName (UnQual (HsSymbol _)) = True
isSymbolName x | (_,_,c:_) <- nameParts (unRename x), isAlpha c || c `elem` "'_" = False
isSymbolName _ = True

ppHsContext :: HsContext -> Doc
ppHsContext []      = empty
ppHsContext context = parenList (map ppHsAsst context)

-- hacked for multi-parameter type classes

ppHsAsst :: HsAsst -> Doc
--ppHsAsst (a,ts) = myFsep(ppHsQName a : map ppHsTypeArg ts)
ppHsAsst (HsAsst a ts) = myFsep(ppHsQName a : map ppHsName ts)
ppHsAsst (HsAsstEq a b) = ppHsType a <+> char '=' <+> ppHsType b

------------------------- pp utils -------------------------
maybePP :: (a -> Doc) -> Maybe a -> Doc
maybePP pp Nothing = empty
maybePP pp (Just a) = pp a

parenList :: [Doc] -> Doc
parenList = parens . myFsepSimple . punctuate comma
parenListzh :: [Doc] -> Doc
parenListzh = parenszh . myFsepSimple . punctuate comma

braceList :: [Doc] -> Doc
braceList = braces . myFsepSimple . punctuate comma

bracketList :: [Doc] -> Doc
bracketList = brackets . myFsepSimple

-- Monadic PP Combinators -- these examine the env

topLevel :: Doc -> [Doc] -> Doc
topLevel header dl = do
	 e <- fmap layout getPPEnv
	 case e of
	     PPOffsideRule -> header $$ vcat dl
	     PPSemiColon -> header $$ (braces . vcat . punctuate semi) dl
	     PPInLine -> header $$ (braces . vcat . punctuate semi) dl
	     PPNoLayout -> header <+> (braces . hsep . punctuate semi) dl

body :: (PPHsMode -> Int) -> [Doc] -> Doc
body f dl = do
	 e <- fmap layout getPPEnv
	 case e of PPOffsideRule -> indent
		   PPSemiColon   -> indentExplicit
		   _ -> inline
		   where
		   inline = braces . hsep . punctuate semi $ dl
		   indent  = do{i <-fmap f getPPEnv;nest i . vcat $ dl}
		   indentExplicit = do {i <- fmap f getPPEnv;
			   nest i . braces . vcat . punctuate semi $ dl}

($$$) :: Doc -> Doc -> Doc
a $$$ b = layoutChoice (a $$) (a <+>) b

mySep :: [Doc] -> Doc
mySep = layoutChoice mySep' hsep
	where
	-- ensure paragraph fills with indentation.
	mySep' [x]    = x
	mySep' (x:xs) = x <+> fsep xs
	mySep' []     = error "Internal error: mySep"

myVcat :: [Doc] -> Doc
myVcat = layoutChoice vcat hsep

myFsepSimple :: [Doc] -> Doc
myFsepSimple = layoutChoice fsep hsep

-- same, except that continuation lines are indented,
-- which is necessary to avoid triggering the offside rule.
myFsep :: [Doc] -> Doc
myFsep = layoutChoice fsep' hsep
	where	fsep' [] = empty
		fsep' (d:ds) = do
			e <- getPPEnv
			let n = onsideIndent e
			nest n (fsep (nest (-n) d:ds))

layoutChoice a b dl = do e <- getPPEnv
                         if layout e == PPOffsideRule ||
                            layout e == PPSemiColon
                          then a dl else b dl

instance P.PPrint P.Doc HsDecl where
    pprint d = unDocM (ppHsDecl d) defaultMode

instance P.PPrint P.Doc HsExp where
    pprint d = unDocM (ppHsExp d) defaultMode

instance P.PPrint P.Doc HsType where
    pprint d = unDocM (ppHsType d) defaultMode

instance P.PPrint P.Doc HsQualType where
    pprint d = unDocM (ppHsQualType d) defaultMode

instance P.PPrint P.Doc  HsTyVarBind where
   pprint d = P.text (show $ hsTyVarBindName d)

instance P.PPrint P.Doc  HsPat where
    pprint d = unDocM (ppHsPat d) defaultMode
