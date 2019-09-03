module CodeGen.CoreImp where
--- Convert CoreFn to KtCore
import Prelude (undefined, error)
import Protolude hiding (Const, const, moduleName, undefined)
import Protolude (unsnoc)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Maybe (catMaybes, fromMaybe, Maybe(..))
import Data.List (nub)
import Debug.Trace (trace)
import Debug.Pretty.Simple (pTrace, pTraceShow, pTraceShowId)
import Language.PureScript.CoreFn.Expr
import Control.Monad.Supply.Class (MonadSupply, fresh)
import Control.Monad (forM, replicateM, void)
import Language.PureScript.CoreFn.Module
import Language.PureScript.CoreFn.Meta
import Language.PureScript.CoreFn.Ann
import Control.Monad.Supply
import Language.PureScript.AST.Literals
import Data.Function (on)
import Data.List (partition)
import Language.PureScript.Names
import Language.PureScript.CoreFn.Traversals
import Language.PureScript.CoreFn.Binders
import Language.PureScript.PSString (prettyPrintStringJS, PSString)
import Data.Text.Prettyprint.Doc
import Text.Pretty.Simple (pShow)
import Debug.Pretty.Simple (pTraceShowId, pTraceShow)
import Language.PureScript.AST.SourcePos (displayStartEndPos)
import CodeGen.Constants
import CodeGen.KtCore
import Data.Maybe  (fromJust)
import CodeGen.Transformations
import Data.Functor.Foldable (Fix(..), cata)


moduleToKt' mod = evalSupply 0 (moduleToKt mod)


data DataTypeDecl = DataTypeDecl
   { typeName :: ProperName TypeName
   , constructors :: [DataCtorDecl]
   }

data DataCtorDecl = DataCtorDecl
   { ctorName :: ProperName ConstructorName
   , parameter :: [Ident]
   }

data Replacement = Replacement
   { ident :: KtIdent
   , replacement :: KtExpr
   }

moduleToKt :: MonadSupply m => Module Ann -> m [KtExpr]
moduleToKt mod = sequence
   [ pure $ packageDecl (moduleName mod)
   , pure $ ktImport [ProperName "Foreign", ProperName "PsRuntime"] (MkKtIdent "app")
   , normalize <$> moduleToObject mod
   ]
   where
      packageDecl :: ModuleName -> KtExpr
      packageDecl (ModuleName mn) = ktPackage $ psNamespace : mn

      moduleToObject :: MonadSupply m => Module Ann -> m KtExpr
      moduleToObject mod = do
         let (normalDecls, classDecls) = splitDeclarations (moduleDecls mod)
         foreigns <- foreignToKt `mapM` moduleForeign mod
         decls <- mapM classDeclsToKt classDecls
         body <- mapM (bindToKt ktJvmValue) normalDecls 
         let objectName = MkKtIdent "Module"
         return $ ktObjectDecl objectName [] $ ktStmt $ foreigns ++ concat decls ++ concat body

      foreignToKt :: MonadSupply m => Ident -> m KtExpr
      foreignToKt ident = do
         ktIdent <- ktIdentFromIdent ident
         let foreignModule = let (ModuleName pns) = moduleName mod in ModuleName $ ProperName "Foreign" : pns
         pure $ ktVariable ktIdent $ ktVarRef (Qualified (Just foreignModule) ktIdent)

      classDeclsToKt :: MonadSupply m => DataTypeDecl -> m [KtExpr]
      classDeclsToKt (DataTypeDecl tyName constructors) = do
         ktName <- identFromTypeName tyName
         ktCtors <- mapM (ctorToKt (varRefUnqual ktName)) constructors
         let classDecl = ktClassDecl [Sealed] ktName [] [] $ ktStmt (fst <$> ktCtors)
         return $ classDecl : (snd <$> ktCtors)

      ctorToKt :: MonadSupply m => KtExpr -> DataCtorDecl -> m (KtExpr, KtExpr)
      ctorToKt parentName (DataCtorDecl ctorName param) = do
         let parentRef = ktCall parentName []
         ktParam <- mapM ktIdentFromIdent param 
         ktName <- identFromCtorName ctorName
         return $
            case param of
               [] ->
                  ( ktObjectDecl ktName [parentRef] (ktStmt [])
                  , ktVariable ktName (ktProperty parentName (varRefUnqual ktName))
                  )
               _ -> 
                  ( ktClassDecl [Data] ktName ktParam [parentRef] (ktStmt [])
                  , ktVariable ktName (lambdaFor ktName [] ktParam)
                  )
         where 
            lambdaFor ktName ktParam [] = ktCall (ktProperty parentName (varRefUnqual ktName)) (varRefUnqual <$> ktParam)
            lambdaFor ktName ktParam (l:ls) = ktLambda l (lambdaFor ktName (ktParam ++ [l]) ls)

      splitDeclarations :: [Bind Ann] -> ([Bind Ann], [DataTypeDecl])
      splitDeclarations binds = (normalBind, typeDecls)
         where 
            (normalBind, ctorBind) = partition (isNothing . getTypeName) binds
            getTypeName (NonRec _ _ (Constructor _ tyName _ _)) = Just tyName
            getTypeName _ = Nothing
            typeDecls = (\binds -> DataTypeDecl (fromJust $ head binds >>= getTypeName) (groupToDecl <$> binds)) <$> groupBy ((==) `on` getTypeName) ctorBind
            groupToDecl :: Bind Ann -> DataCtorDecl
            groupToDecl (NonRec _ _ (Constructor _ _ ctorName idents)) = DataCtorDecl ctorName idents

      bindToKt :: MonadSupply m => (KtExpr -> KtExpr) -> Bind Ann -> m ([KtExpr], [KtExpr]) -- (normal, recursive)
      --TODO: split binder into (Constructor ...) and others
      bindToKt modDecls (NonRec _ ident val) = do
            ktVal <- exprToKt val
            ktIdent <- ktIdentFromIdent ident
            return [ modDecls $ ktVariable ktIdent ktVal ]
      bindToKt modDecls (Rec bindings) = do
         converted <- mapM go bindings
         pure $ replaceRecNames (snd <$> converted) <$> concat (fst <$> converted)
         where
            genRecTxt name = "_rec_"<> name
            genRecName (MkKtIdent name) = MkKtIdent $ "_" <> genRecTxt name
            replaceRecNames :: [(KtIdent, KtIdent)] -> KtExpr -> KtExpr
            replaceRecNames replacements expr = foldr replaceRecName expr replacements
            replaceRecName :: (KtIdent, KtIdent) -> KtExpr -> KtExpr
            replaceRecName (original, new) = cata (Fix . alg) where
               alg (VarRef (Qualified modName' name)) 
                  | (name == original) && maybe True (== moduleName mod) modName' = 
                     Call (varRefUnqual new) []
               alg a = a
            go :: MonadSupply m => ((a, Ident), Expr Ann) -> m ([KtExpr], (KtIdent, KtIdent)) -- (decls, (normalIdent, recIdent))
            go ((_, ident), val) = do
               ktVal <- exprToKt val
               ktIdent <- ktIdentFromIdent ident
               let recFuncName = genRecName ktIdent
               let normalVar = modDecls $ ktVariable ktIdent $ ktCall (ktFunRef (Qualified Nothing recFuncName)) []
               return ([ ktFun' (Just recFuncName) [] ktVal, normalVar ], (ktIdent, recFuncName))
            -- recursion with anything but a abs
            -- for this, the value is turned into a argumentless function and called to get the value
            -- go ((_, ident), a) = return $ pTraceShow bindings undefined

      exprToKt :: MonadSupply m => Expr Ann -> m KtExpr
      exprToKt (Var _ qualIdent) = qualifiedIdentToKt qualIdent
      exprToKt (Abs _ arg body) = do 
         ktArg <- ktIdentFromIdent arg
         ktBody <- exprToKt body
         return $ ktLambda ktArg ktBody
      exprToKt (Literal _ literal) = ktConst <$> forMLiteral literal exprToKt
      exprToKt (App _ a b) = do
         aKt <- exprToKt a
         bKt <- exprToKt b
         return $ ktCall (ktProperty aKt (varRefUnqual $ MkKtIdent "app")) [bKt]
      exprToKt (Case _ compareVals caseAlternatives) = ktWhenExpr . concat <$> mapM (caseToKt compareVals) caseAlternatives
      exprToKt (Accessor _ key obj) = do
         ktObj <- exprToKt obj
         return $ ktObjectAccess (ktCast ktObj $ varRefUnqual mapType) (ktString key)
      exprToKt (Let _ binds body) = do
         ktBinds <- concatMapM (bindToKt identity) binds 
         ktBody <- exprToKt body
         let ktObj = ktUnnamedObj [] $ ktStmt ktBinds
         return $ ktCall (ktProperty ktObj (varRefUnqual $ MkKtIdent "run")) [ktStmt [ktBody]]--(ktStmt $ ktBinds ++ [ktBody]) [] -- TODO: limit to situations where wrapping in call is necessary
      exprToKt a = pTraceShow a undefined
      
      caseToKt :: MonadSupply m => [Expr Ann] -> CaseAlternative Ann -> m [WhenCase KtExpr]
      caseToKt compareVals (CaseAlternative binders caseResult) = do
         ktCompareVals <- mapM exprToKt compareVals
         (guards, replacements) <- transposeTuple <$> zipWithM binderToKt ktCompareVals binders
         let assignments = replacementToAssignment <$> concat replacements
         case caseResult of
            (Right result) -> do
               ktBody <- exprToKt result
               pure [WhenCase (concat guards) (ktStmt $ assignments ++ [ktBody])]
            (Left guardedExpr) -> traverse genGuard guardedExpr
               where 
                  genGuard (cond, val) = do
                     ktCond <- ktAsBool . replaceBindersWithReferences (concat replacements) <$> exprToKt cond
                     ktVal <- exprToKt val
                     pure $ WhenCase (concat guards ++ [ktCond]) (ktStmt $ assignments ++ [ktVal])

      replaceBindersWithReferences :: [Replacement] -> KtExpr -> KtExpr
      replaceBindersWithReferences replacements expr = foldr (cata . alg) expr replacements
         where
            alg (Replacement ident ref) (VarRef (Qualified Nothing ident')) | ident == ident' = ref
            alg _ a = Fix a

      binderToKt :: MonadSupply m => KtExpr -> Binder Ann -> m ([KtExpr], [Replacement]) -- ([binder], [{identToReplace, exprThatReplacesIt}])
      binderToKt compareVal (VarBinder _ ident) = do
         ktIdent <- ktIdentFromIdent ident
         pure 
            ( []
            , [Replacement ktIdent compareVal]
            )
      binderToKt compareVal (LiteralBinder _ literal) = do
         literalValue <- forMLitKey literal
            (binderToKt . ktArrayAccess compareVal . ktInt)
            (binderToKt . ktObjectAccess compareVal . ktString)
         pure 
            ( specificGuard literal : fold (fst <$> literalValue)
            , fold (snd <$> literalValue)
            )
         where
            specificGuard (ArrayLiteral a) = 
               ktEq (getLength compareVal) (ktInt $ fromIntegral $ length a)
            specificGuard (ObjectLiteral a) = 
               ktEq (getEntryCount compareVal) (ktInt $ fromIntegral $ length a)
            specificGuard (NumericLiteral a) = ktEq compareVal $ ktConst $ NumericLiteral a
            specificGuard (StringLiteral a) = ktEq compareVal $ ktConst $ StringLiteral a
            specificGuard (CharLiteral a) = ktEq compareVal $ ktConst $ CharLiteral a
            specificGuard (BooleanLiteral a) = ktEq compareVal $ ktConst $ BooleanLiteral a
      binderToKt _ NullBinder{} = pure ([], [])
      binderToKt compareVal (ConstructorBinder (_, _, _, Just (IsConstructor _ ctorParams)) tyName ctorName subBinders) = do
         ktTypeIdent <- qualifiedToKt identFromTypeName tyName
         (Qualified _ ktCtorName) <- qualifiedToKt identFromCtorName ctorName
         ktCtorParams <- mapM ktIdentFromIdent ctorParams
         subBindersExprs <- zipWithM (\ident binder -> binderToKt (ktProperty compareVal (varRefUnqual ident)) binder) ktCtorParams subBinders
         pure
            ( ktIsType compareVal (ktProperty (ktVarRef ktTypeIdent) (varRefUnqual ktCtorName)) : concat (fst <$> subBindersExprs)
            , concat $ snd <$> subBindersExprs
            )
      binderToKt compareVal (ConstructorBinder (_, _, _, Just IsNewtype) tyName ctorName [subBinder]) = do
         (guards, stmts) <- binderToKt compareVal subBinder 
         pure
            ( guards
            , stmts
            )
      binderToKt compareVal (NamedBinder _ ident subBinder) = do
         ktIdent <- ktIdentFromIdent ident
         (guards, replacements) <- binderToKt compareVal subBinder
         pure 
            ( guards
            , Replacement ktIdent compareVal : replacements
            )
      binderToKt compareVal binder = pure $ pTraceShow (compareVal, binder) undefined

      replacementToAssignment :: Replacement -> KtExpr
      replacementToAssignment (Replacement ident val) = ktVariable ident val

transposeTuple :: [(a, b)] -> ([a], [b])
transposeTuple ls = (fst <$> ls, snd <$> ls)

splitLast :: a -> [a] -> ([a], a)
splitLast pre [] = ([pre], pre)
splitLast pre [l] = ([pre], l)
splitLast pre (l:ls) = (\(a, b) -> (pre :a, b)) $ splitLast l ls