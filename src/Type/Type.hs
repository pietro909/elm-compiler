{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module Type.Type
  ( Variable
  , FlatType(..)
  , Type(..)
  , Descriptor(Descriptor)
  , Content(..)
  , noRank
  , outermostRank
  , Mark
  , noMark
  , nextMark
  , (==>)
  , int, float, char, string, bool
  , vec2, vec3, vec4, mat4, texture
  , mkFlexVar
  , mkFlexNumber
  , unnamedFlexVar
  , unnamedFlexSuper
  , nameToFlex
  , nameToRigid
  , toSrcType
  )
  where


import Control.Monad.State.Strict (StateT, liftIO)
import qualified Control.Monad.State.Strict as State
import qualified Data.Char as Char
import Data.Foldable (foldrM)
import qualified Data.Map.Strict as Map
import Data.Monoid ((<>))
import qualified Data.Text as Text
import Data.Text (Text)
import Data.Word (Word32)

import qualified AST.Module.Name as ModuleName
import qualified AST.Type as T
import qualified Elm.Name as N
import qualified Type.UnionFind as UF



-- TYPE PRIMITIVES


type Variable =
    UF.Point Descriptor


data FlatType
    = App1 ModuleName.Canonical N.Name [Variable]
    | Fun1 Variable Variable
    | EmptyRecord1
    | Record1 (Map.Map N.Name Variable) Variable
    | Unit1
    | Tuple1 Variable Variable (Maybe Variable)


data Type
    = PlaceHolder N.Name
    | AliasN ModuleName.Canonical N.Name [(N.Name, Type)] Type
    | VarN Variable
    | AppN ModuleName.Canonical N.Name [Type]
    | FunN Type Type
    | EmptyRecordN
    | RecordN (Map.Map N.Name Type) Type
    | UnitN
    | TupleN Type Type (Maybe Type)



-- DESCRIPTORS


data Descriptor =
  Descriptor
    { _content :: Content
    , _rank :: Int
    , _mark :: Mark
    , _copy :: Maybe Variable
    }


data Content
    = FlexVar (Maybe N.Name)
    | FlexSuper T.Super (Maybe N.Name)
    | RigidVar N.Name
    | RigidSuper T.Super N.Name
    | Structure FlatType
    | Alias ModuleName.Canonical N.Name [(N.Name,Variable)] Variable
    | Error Text


makeDescriptor :: Content -> Descriptor
makeDescriptor content =
  Descriptor content noRank noMark Nothing



-- RANKS


noRank :: Int
noRank =
  0


outermostRank :: Int
outermostRank =
  1



-- MARKS


newtype Mark = Mark Word32
  deriving (Eq, Ord)


noMark :: Mark
noMark =
  Mark 2


occursMark :: Mark
occursMark =
  Mark 1


getVarNamesMark :: Mark
getVarNamesMark =
  Mark 0


{-# INLINE nextMark #-}
nextMark :: Mark -> Mark
nextMark (Mark mark) =
  Mark (mark + 1)



-- FUNCTION TYPES


infixr 9 ==>


{-# INLINE (==>) #-}
(==>) :: Type -> Type -> Type
(==>) =
  FunN



-- PRIMITIVE TYPES


{-# NOINLINE int #-}
int :: Type
int = AppN ModuleName.basics "Int" []


{-# NOINLINE float #-}
float :: Type
float = AppN ModuleName.basics "Float" []


{-# NOINLINE char #-}
char :: Type
char = AppN ModuleName.char "Char" []


{-# NOINLINE string #-}
string :: Type
string = AppN ModuleName.string "String" []


{-# NOINLINE bool #-}
bool :: Type
bool = AppN ModuleName.basics "Bool" []



-- WEBGL TYPES


{-# NOINLINE vec2 #-}
vec2 :: Type
vec2 = AppN ModuleName.vector2 "Vec2" []


{-# NOINLINE vec3 #-}
vec3 :: Type
vec3 = AppN ModuleName.vector3 "Vec3" []


{-# NOINLINE vec4 #-}
vec4 :: Type
vec4 = AppN ModuleName.vector4 "Vec4" []


{-# NOINLINE mat4 #-}
mat4 :: Type
mat4 = AppN ModuleName.matrix4 "Mat4" []


{-# NOINLINE texture #-}
texture :: Type
texture = AppN ModuleName.webgl "Texture" []



-- MAKE FLEX VARIABLES


mkFlexVar :: IO Variable
mkFlexVar =
  UF.fresh flexVarDescriptor


{-# NOINLINE flexVarDescriptor #-}
flexVarDescriptor :: Descriptor
flexVarDescriptor =
  makeDescriptor unnamedFlexVar


{-# NOINLINE unnamedFlexVar #-}
unnamedFlexVar :: Content
unnamedFlexVar =
  FlexVar Nothing



-- MAKE FLEX NUMBERS


mkFlexNumber :: IO Variable
mkFlexNumber =
  UF.fresh flexNumberDescriptor


{-# NOINLINE flexNumberDescriptor #-}
flexNumberDescriptor :: Descriptor
flexNumberDescriptor =
  makeDescriptor (unnamedFlexSuper T.Number)


unnamedFlexSuper :: T.Super -> Content
unnamedFlexSuper super =
  FlexSuper super Nothing



-- MAKE NAMED VARIABLES


nameToFlex :: N.Name -> IO Variable
nameToFlex name =
  UF.fresh $ makeDescriptor $
    maybe FlexVar FlexSuper (toSuper name) (Just name)


nameToRigid :: N.Name -> IO Variable
nameToRigid name =
  UF.fresh $ makeDescriptor $
    maybe RigidVar RigidSuper (toSuper name) name


toSuper :: N.Name -> Maybe T.Super
toSuper name =
  if Text.isPrefixOf "number" name then
      Just T.Number

  else if Text.isPrefixOf "comparable" name then
      Just T.Comparable

  else if Text.isPrefixOf "appendable" name then
      Just T.Appendable

  else if Text.isPrefixOf "compappend" name then
      Just T.CompAppend

  else
      Nothing



-- TO SOURCE TYPES


-- TODO: Attach resulting type to the descriptor so that you
-- never have to do extra work, particularly nice for aliased types
toSrcType :: Variable -> IO T.Canonical
toSrcType variable =
  do  takenNames <- getVarNames variable Map.empty
      State.evalStateT (variableToSrcType variable) (makeNameState takenNames)


variableToSrcType :: Variable -> StateT NameState IO T.Canonical
variableToSrcType variable =
  do  descriptor <- liftIO $ UF.descriptor variable
      let mark = _mark descriptor
      if mark == occursMark
        then
          return (T.Var "∞")

        else
          do  liftIO $ UF.modifyDescriptor variable (\desc -> desc { _mark = occursMark })
              srcType <- contentToSrcType variable (_content descriptor)
              liftIO $ UF.modifyDescriptor variable (\desc -> desc { _mark = mark })
              return srcType


contentToSrcType :: Variable -> Content -> StateT NameState IO T.Canonical
contentToSrcType variable content =
  case content of
    Structure term ->
        termToSrcType term

    FlexVar maybeName ->
      case maybeName of
        Just name ->
          return (T.Var name)

        Nothing ->
          do  name <- getFreshVarName
              liftIO $ UF.modifyDescriptor variable (\desc -> desc { _content = FlexVar (Just name) })
              return (T.Var name)

    FlexSuper super maybeName ->
      case maybeName of
        Just name ->
          return (T.Var name)

        Nothing ->
          do  name <- getFreshSuperName super
              liftIO $ UF.modifyDescriptor variable (\desc -> desc { _content = FlexSuper super (Just name) })
              return (T.Var name)

    RigidVar name ->
        return (T.Var name)

    RigidSuper _ name ->
        return (T.Var name)

    Alias home name args realVariable ->
        do  srcArgs <- traverse (traverse variableToSrcType) args
            srcType <- variableToSrcType realVariable
            return (T.Aliased home name srcArgs (T.Filled srcType))

    Error name ->
        return (T.Var name)


termToSrcType :: FlatType -> StateT NameState IO T.Canonical
termToSrcType term =
  case term of
    App1 home name args ->
      T.Type home name <$> traverse variableToSrcType args

    Fun1 a b ->
      T.Lambda
        <$> variableToSrcType a
        <*> variableToSrcType b

    EmptyRecord1 ->
      return $ T.Record Map.empty Nothing

    Record1 fields extension ->
      do  srcFields <- traverse variableToSrcType fields
          srcExt <- T.iteratedDealias <$> variableToSrcType extension
          return $
              case srcExt of
                T.Record subFields subExt ->
                    T.Record (Map.union subFields srcFields) subExt

                T.Var _ ->
                    T.Record srcFields (Just srcExt)

                _ ->
                    error "Used toSrcType on a type that is not well-formed"

    Unit1 ->
      return T.Unit

    Tuple1 a b maybeC ->
      T.Tuple
        <$> variableToSrcType a
        <*> variableToSrcType b
        <*> traverse variableToSrcType maybeC



-- MANAGE FRESH VARIABLE NAMES


data NameState =
  NameState
    { _taken :: TakenNames
    , _normals :: Int
    , _numbers :: Int
    , _comparables :: Int
    , _appendables :: Int
    , _compAppends :: Int
    }


type TakenNames = Map.Map Text Variable


makeNameState :: TakenNames -> NameState
makeNameState taken =
  NameState taken 0 0 0 0 0


getFreshVarName :: (Monad m) => StateT NameState m Text
getFreshVarName =
  do  index <- State.gets _normals
      taken <- State.gets _taken
      let (uniqueName, newIndex) = getFreshNormal index taken
      State.modify (\state -> state { _normals = newIndex })
      return uniqueName


getFreshSuperName :: (Monad m) => T.Super -> StateT NameState m Text
getFreshSuperName super =
  case super of
    T.Number ->
      getFreshSuper "number" _numbers (\index state -> state { _numbers = index })

    T.Comparable ->
      getFreshSuper "comparable" _comparables (\index state -> state { _comparables = index })

    T.Appendable ->
      getFreshSuper "appendable" _appendables (\index state -> state { _appendables = index })

    T.CompAppend ->
      getFreshSuper "compappend" _compAppends (\index state -> state { _compAppends = index })


getFreshNormal :: Int -> TakenNames -> (Text, Int)
getFreshNormal index taken =
  let
    (postfix, letter) =
      quotRem index 26

    character =
      Char.chr (97 + letter)

    name =
      Text.pack (if postfix <= 0 then [character] else character : show postfix)
  in
    if Map.member name taken then
      getFreshNormal (index + 1) taken

    else
      (name, index + 1)


getFreshSuper
    :: (Monad m)
    => Text
    -> (NameState -> Int)
    -> (Int -> NameState -> NameState)
    -> StateT NameState m Text
getFreshSuper name getter setter =
  do  index <- State.gets getter
      taken <- State.gets _taken
      let (uniqueName, newIndex) = getFreshSuperHelp name index taken
      State.modify (setter newIndex)
      return uniqueName


getFreshSuperHelp :: Text -> Int -> TakenNames -> (Text, Int)
getFreshSuperHelp name index taken =
  let
    newName =
      if index <= 0 then name else name <> Text.pack (show index)
  in
    if Map.member newName taken then
      getFreshSuperHelp name (index + 1) taken

    else
      (newName, index + 1)



-- GET ALL VARIABLE NAMES


getVarNames :: Variable -> TakenNames -> IO TakenNames
getVarNames var takenNames =
  do  (Descriptor content rank mark copy) <- UF.descriptor var
      if mark == getVarNamesMark
        then return takenNames
        else
        do  UF.setDescriptor var (Descriptor content rank getVarNamesMark copy)
            case content of
              Error _ ->
                return takenNames

              FlexVar maybeName ->
                case maybeName of
                  Nothing ->
                    return takenNames

                  Just name ->
                    addName 0 name var (FlexVar . Just) takenNames

              FlexSuper super maybeName ->
                case maybeName of
                  Nothing ->
                    return takenNames

                  Just name ->
                    addName 0 name var (FlexSuper super . Just) takenNames

              RigidVar name ->
                addName 0 name var RigidVar takenNames

              RigidSuper super name ->
                addName 0 name var (RigidSuper super) takenNames

              Alias _ _ args _ ->
                foldrM getVarNames takenNames (map snd args)

              Structure flatType ->
                case flatType of
                  App1 _ _ args ->
                    foldrM getVarNames takenNames args

                  Fun1 arg body ->
                    getVarNames arg =<< getVarNames body takenNames

                  EmptyRecord1 ->
                    return takenNames

                  Record1 fields extension ->
                    getVarNames extension =<<
                      foldrM getVarNames takenNames (Map.elems fields)

                  Unit1 ->
                    return takenNames

                  Tuple1 a b Nothing ->
                    getVarNames a =<< getVarNames b takenNames

                  Tuple1 a b (Just c) ->
                    getVarNames a =<< getVarNames b =<< getVarNames c takenNames



-- REGISTER NAME / RENAME DUPLICATES


addName :: Int -> N.Name -> Variable -> (N.Name -> Content) -> TakenNames -> IO TakenNames
addName index givenName var makeContent takenNames =
  let
    indexedName =
      if index <= 0 then
        givenName
      else if Char.isDigit (Text.last givenName) then
        givenName <> Text.pack ('_' : show index)
      else
        givenName <> Text.pack (show index)
  in
    case Map.lookup indexedName takenNames of
      Nothing ->
        do  if indexedName == givenName then return () else
              UF.modifyDescriptor var $ \(Descriptor _ rank mark copy) ->
                Descriptor (makeContent indexedName) rank mark copy
            return $ Map.insert indexedName var takenNames

      Just otherVar ->
        do  same <- UF.equivalent var otherVar
            if same
              then return takenNames
              else addName (index + 1) givenName var makeContent takenNames
