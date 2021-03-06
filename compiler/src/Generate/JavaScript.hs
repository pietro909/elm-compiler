{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module Generate.JavaScript
  ( Mode(..)
  , generate
  , generateForRepl
  )
  where


import Prelude hiding (cycle, print)
import qualified Data.ByteString.Builder as B
import Data.Monoid ((<>))
import qualified Data.List as List
import Data.Map ((!))
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text

import qualified AST.Optimized as Opt
import qualified AST.Module.Name as ModuleName
import qualified Data.Index as Index
import qualified Elm.Compiler.Type as Type
import qualified Elm.Compiler.Type.Extract as Extract
import qualified Elm.Interface as I
import qualified Elm.Name as N
import qualified Generate.JavaScript.Builder as JS
import qualified Generate.JavaScript.Expression as Expr
import qualified Generate.JavaScript.Name as Name
import qualified Reporting.Helpers as H



-- GENERATE MAINS


data Mode = Debug | Prod


generate :: Mode -> Name.Target -> I.Interfaces -> Opt.Graph -> [ModuleName.Canonical] -> Either [ModuleName.Canonical] B.Builder
generate mode target interfaces (Opt.Graph mains graph fields) roots =
  let
    rootSet = Set.fromList roots
    rootMap = Map.restrictKeys mains rootSet
  in
  if Map.size rootMap == Set.size rootSet then
    let
      realMode = toRealMode mode target fields
      state = Map.foldrWithKey (addMain realMode graph) emptyState rootMap
    in
    Right $ stateToBuilder state <> toMainExports realMode interfaces rootMap

  else
    Left $ Set.toList $
      Set.intersection rootSet (Map.keysSet mains)


addMain :: Name.Mode -> Graph -> ModuleName.Canonical -> main -> State -> State
addMain mode graph home _ state =
  addGlobal mode graph state (Opt.Global home "main")


toRealMode :: Mode -> Name.Target -> Map.Map N.Name Int -> Name.Mode
toRealMode mode target fields =
  case mode of
    Debug ->
      Name.Debug target

    Prod ->
      Name.Prod target (Name.shortenFieldNames fields)



-- GENERATE FOR REPL


generateForRepl :: I.Interfaces -> Opt.Graph -> ModuleName.Canonical -> N.Name -> B.Builder
generateForRepl interfaces (Opt.Graph _ graph _) home name =
  let
    mode = Name.Debug Name.Server
    eval = addGlobal mode graph emptyState (Opt.Global home name)
  in
  stateToBuilder eval <> print interfaces home name


print :: I.Interfaces -> ModuleName.Canonical -> N.Name -> B.Builder
print interfaces home name =
  let
    value = Name.toBuilder (Name.fromGlobal home name)
    toString = Name.toBuilder (Name.fromKernel N.debug "toString")
    annotation = I._types (interfaces ! home) ! name
    tipe = Type.toString Type.MultiLine $ Extract.fromAnnotation annotation
  in
    "var _value = " <> toString <> "(" <> value <> ");\n" <>
    "var _type = '" <> B.stringUtf8 (show tipe) <> "';\n\
    \if (_value.length + 3 + _type.length >= 80 || _type.indexOf('\\n') >= 0) {\n\
    \    console.log(_value + '\\n    : ' + _type.split('\\n').join('\\n      '));\n\
    \} else {\n\
    \    console.log(_value + ' : ' + _type);\n\
    \}\n"



-- GRAPH TRAVERSAL STATE


data State =
  State
    { _revBuilders :: [B.Builder]
    , _seenGlobals :: Set.Set Opt.Global
    }


emptyState :: State
emptyState =
  State [] Set.empty


stateToBuilder :: State -> B.Builder
stateToBuilder (State revBuilders _) =
  List.foldl1' (\builder b -> b <> builder) revBuilders



-- ADD DEPENDENCIES


type Graph = Map.Map Opt.Global Opt.Node


addGlobal :: Name.Mode -> Graph -> State -> Opt.Global -> State
addGlobal mode graph state@(State builders seen) global =
  if Set.member global seen then
    state
  else
    addGlobalHelp mode graph global $
      State builders (Set.insert global seen)


addGlobalHelp :: Name.Mode -> Graph -> Opt.Global -> State -> State
addGlobalHelp mode graph global state =
  let
    addDeps deps someState =
      Set.foldl' (addGlobal mode graph) someState deps
  in
  case graph ! global of
    Opt.Define expr deps ->
      addStmt (addDeps deps state) (
        var global (Expr.generate mode expr)
      )

    Opt.DefineTailFunc argNames body deps ->
      addStmt (addDeps deps state) (
        let (Opt.Global _ name) = global in
        var global (Expr.generateTailDef mode name argNames body)
      )

    Opt.Ctor name index arity ->
      addStmt state (
        var global (Expr.generateCtor mode name index arity)
      )

    Opt.Link linkedGlobal ->
      addGlobal mode graph state linkedGlobal

    Opt.Cycle cycle deps ->
      addStmt (addDeps deps state) (
        generateCycle mode global cycle
      )

    Opt.Manager effectsType ->
      generateManager mode graph global effectsType state

    Opt.Kernel (Opt.KContent clientChunks clientDeps) maybeServer ->
      case maybeServer of
        Just (Opt.KContent serverChunks serverDeps) | Name.isServer mode ->
          addBuilder (addDeps serverDeps state) (generateKernel mode serverChunks)

        _ ->
          addBuilder (addDeps clientDeps state) (generateKernel mode clientChunks)

    Opt.Enum name index ->
      addStmt state (
        generateEnum mode global name index
      )

    Opt.Box name ->
      addStmt state (
        generateBox mode global name
      )

    Opt.PortIncoming decoder deps ->
      addStmt (addDeps deps state) (
        generatePort mode global "incomingPort" decoder
      )

    Opt.PortOutgoing encoder deps ->
      addStmt (addDeps deps state) (
        generatePort mode global "outgoingPort" encoder
      )


addStmt :: State -> JS.Stmt -> State
addStmt state stmt =
  addBuilder state (JS.stmtToBuilder stmt)


addBuilder :: State -> B.Builder -> State
addBuilder (State revBuilders seen) builder =
  State (builder:revBuilders) seen


var :: Opt.Global -> Expr.Code -> JS.Stmt
var (Opt.Global home name) code =
  JS.Var [ (Name.fromGlobal home name, Just (Expr.codeToExpr code)) ]



-- GENERATE CYCLES


generateCycle :: Name.Mode -> Opt.Global -> [(N.Name, Opt.Expr)] -> JS.Stmt
generateCycle mode (Opt.Global home _) cycle =
  let
    safeDefs = map (generateSafeCycle mode home) cycle
    realDefs = map (generateRealCycle home) cycle
    block = JS.Block (safeDefs ++ realDefs)
  in
  case mode of
    Name.Prod _ _ ->
      block

    Name.Debug _ ->
      JS.Try block Name.dollar $ JS.Throw $ JS.String $
        "The following top-level definitions are causing infinite recursion:\\n"
        <> drawCycle (map fst cycle)
        <> "\\n\\nThese errors are very tricky, so read "
        <> B.stringUtf8 (H.makeLink "halting-problem")
        <> " to learn how to fix it!"


generateSafeCycle :: Name.Mode -> ModuleName.Canonical -> (N.Name, Opt.Expr) -> JS.Stmt
generateSafeCycle mode home (name, expr) =
  JS.FunctionStmt (Name.fromCycle home name) [] $
    Expr.codeToStmtList (Expr.generate mode expr)


generateRealCycle :: ModuleName.Canonical -> (N.Name, expr) -> JS.Stmt
generateRealCycle home (name, _) =
  let
    safeName = Name.fromCycle home name
    realName = Name.fromGlobal home name
  in
  JS.Block
    [ JS.Var [ ( realName, Just (JS.Call (JS.Ref safeName) []) ) ]
    , JS.ExprStmt $ JS.Assign (JS.LRef safeName) $
        JS.Function Nothing [] [ JS.Return (Just (JS.Ref realName)) ]
    ]


drawCycle :: [N.Name] -> B.Builder
drawCycle names =
  let
    topLine       = "\\n  ┌─────┐"
    nameLine name = "\\n  │    " <> N.toBuilder name
    midLine       = "\\n  │     ↓"
    bottomLine    = "\\n  └─────┘"
  in
    mconcat (topLine : List.intersperse midLine (map nameLine names) ++ [ bottomLine ])




-- GENERATE KERNEL


generateKernel :: Name.Mode -> [Opt.KChunk] -> B.Builder
generateKernel mode chunks =
  List.foldl' (addChunk mode) mempty chunks


addChunk :: Name.Mode -> B.Builder -> Opt.KChunk -> B.Builder
addChunk mode builder chunk =
  case chunk of
    Opt.JS javascript ->
      B.byteString javascript <> builder

    Opt.ElmVar home name ->
      Name.toBuilder (Name.fromGlobal home name) <> builder

    Opt.JsVar home name ->
      Name.toBuilder (Name.fromKernel home name) <> builder

    Opt.ElmField name ->
      Name.toBuilder (Name.fromField mode name) <> builder

    Opt.JsField int ->
      Name.toBuilder (Name.fromInt int) <> builder

    Opt.JsEnum int ->
      B.intDec int <> builder

    Opt.Debug ->
      case mode of
        Name.Debug _ ->
          builder

        Name.Prod _ _ ->
          "_UNUSED" <> builder

    Opt.Prod ->
      case mode of
        Name.Debug _ ->
          "_UNUSED" <> builder

        Name.Prod _ _ ->
          builder



-- GENERATE ENUM


generateEnum :: Name.Mode -> Opt.Global -> N.Name -> Index.ZeroBased -> JS.Stmt
generateEnum mode (Opt.Global home name) ctorName index =
  let
    definition =
      case mode of
        Name.Debug _ ->
          Expr.codeToExpr (Expr.generateCtor mode ctorName index 0)

        Name.Prod _ _ ->
          JS.Int (Index.toMachine index)
  in
  JS.Var [ (Name.fromGlobal home name, Just definition) ]



-- GENERATE BOX


generateBox :: Name.Mode -> Opt.Global -> N.Name -> JS.Stmt
generateBox mode (Opt.Global home name) ctorName =
  let
    definition =
      case mode of
        Name.Debug _ ->
          Expr.codeToExpr (Expr.generateCtor mode ctorName Index.first 1)

        Name.Prod _ _ ->
          JS.Ref (Name.fromGlobal ModuleName.basics N.identity)
  in
  JS.Var [ (Name.fromGlobal home name, Just definition) ]



-- GENERATE PORTS


generatePort :: Name.Mode -> Opt.Global -> N.Name -> Opt.Expr -> JS.Stmt
generatePort mode (Opt.Global home name) makePort converter =
  let
    definition =
      JS.Call (JS.Ref (Name.fromKernel N.platform makePort))
        [ JS.String (N.toBuilder name)
        , Expr.codeToExpr (Expr.generate mode converter)
        ]
  in
  JS.Var [ (Name.fromGlobal home name, Just definition) ]



-- GENERATE MANAGER


generateManager :: Name.Mode -> Graph -> Opt.Global -> Opt.EffectsType -> State -> State
generateManager mode graph (Opt.Global home@(ModuleName.Canonical _ moduleName) _) effectsType state =
  let
    managerLVar =
      JS.LBracket
        (JS.Ref (Name.fromKernel N.platform "effectManagers"))
        (JS.String (N.toBuilder moduleName))

    (deps, args, stmts) =
      generateManagerHelp home effectsType

    createManager =
      JS.ExprStmt $ JS.Assign managerLVar $
        JS.Call (JS.Ref (Name.fromKernel N.platform "createManager")) args
  in
  addStmt (List.foldl' (addGlobal mode graph) state deps) $
    JS.Block (createManager : stmts)


generateLeaf :: ModuleName.Canonical -> N.Name -> JS.Stmt
generateLeaf home@(ModuleName.Canonical _ moduleName) name =
  let
    definition =
      JS.Call leaf [ JS.String (N.toBuilder moduleName) ]
  in
  JS.Var [ (Name.fromGlobal home name, Just definition) ]


{-# NOINLINE leaf #-}
leaf :: JS.Expr
leaf =
  JS.Ref (Name.fromKernel N.platform "leaf")


generateManagerHelp :: ModuleName.Canonical -> Opt.EffectsType -> ([Opt.Global], [JS.Expr], [JS.Stmt])
generateManagerHelp home effectsType =
  let
    dep name = Opt.Global home name
    ref name = JS.Ref (Name.fromGlobal home name)
  in
  case effectsType of
    Opt.Cmd ->
      ( [ dep "init", dep "onEffects", dep "onSelfMsg", dep "cmdMap" ]
      , [ ref "init", ref "onEffects", ref "onSelfMsg", ref "cmdMap" ]
      , [ generateLeaf home "command" ]
      )

    Opt.Sub ->
      ( [ dep "init", dep "onEffects", dep "onSelfMsg", dep "subMap" ]
      , [ ref "init", ref "onEffects", ref "onSelfMsg", JS.Int 0, ref "subMap" ]
      , [ generateLeaf home "subscription" ]
      )

    Opt.Fx ->
      ( [ dep "init", dep "onEffects", dep "onSelfMsg", dep "cmdMap", dep "subMap" ]
      , [ ref "init", ref "onEffects", ref "onSelfMsg", ref "cmdMap", ref "subMap" ]
      , [ generateLeaf home "command"
        , generateLeaf home "subscription"
        ]
      )



-- MAIN EXPORTS


toMainExports :: Name.Mode -> I.Interfaces -> Map.Map ModuleName.Canonical Opt.Main -> B.Builder
toMainExports mode interfaces mains =
  let
    export =
      Name.fromKernel N.platform "export"

    exports =
      generateExports mode interfaces $
        Map.foldrWithKey addToTrie emptyTrie mains
  in
  Name.toBuilder export <> "(" <> exports <> ");"


generateExports :: Name.Mode -> I.Interfaces -> Trie -> B.Builder
generateExports mode interfaces (Trie maybeMain subs) =
  let
    object =
      case Map.toList subs of
        [] ->
          "{}"

        (name, subTrie) : otherSubTries ->
          "{'" <> Text.encodeUtf8Builder name <> "':"
          <> generateExports mode interfaces subTrie
          <> List.foldl' (addSubTrie mode interfaces) "}" otherSubTries
  in
  case maybeMain of
    Nothing ->
      object

    Just (home, main) ->
      let initialize = Expr.generateMain mode interfaces home main in
      JS.exprToBuilder initialize <> "(" <> object <> ")"


addSubTrie :: Name.Mode -> I.Interfaces -> B.Builder -> (Text.Text, Trie) -> B.Builder
addSubTrie mode interfaces end (name, trie) =
  ",'" <> Text.encodeUtf8Builder name <> "':"
  <> generateExports mode interfaces trie
  <> end



-- BUILD TRIES


data Trie =
  Trie
    { _main :: Maybe (ModuleName.Canonical, Opt.Main)
    , _subs :: Map.Map Text.Text Trie
    }


emptyTrie :: Trie
emptyTrie =
  Trie Nothing Map.empty


addToTrie :: ModuleName.Canonical -> Opt.Main -> Trie -> Trie
addToTrie home@(ModuleName.Canonical _ moduleName) main trie =
  merge trie $ segmentsToTrie home (Text.splitOn "." (N.toText moduleName)) main


segmentsToTrie :: ModuleName.Canonical -> [Text.Text] -> Opt.Main -> Trie
segmentsToTrie home segments main =
  case segments of
    [] ->
      Trie (Just (home, main)) Map.empty

    segment : otherSegments ->
      Trie Nothing (Map.singleton segment (segmentsToTrie home otherSegments main))


merge :: Trie -> Trie -> Trie
merge (Trie main1 subs1) (Trie main2 subs2) =
  Trie
    (checkedMerge main1 main2)
    (Map.unionWith merge subs1 subs2)


checkedMerge :: Maybe a -> Maybe a -> Maybe a
checkedMerge a b =
  case (a, b) of
    (Nothing, main) ->
      main

    (main, Nothing) ->
      main

    (Just _, Just _) ->
      error "cannot have two modules with the same name"
