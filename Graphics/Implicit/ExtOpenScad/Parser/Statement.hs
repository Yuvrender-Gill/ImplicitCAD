-- Implicit CAD. Copyright (C) 2011, Christopher Olah (chris@colah.ca)
-- Copyright 2014 2015 2016, Julia Longtin (julial@turinglace.com)
-- Released under the GNU AGPLV3+, see LICENSE

-- Allow us to use explicit foralls when writing function type declarations.
{-# LANGUAGE ExplicitForAll #-}

-- FIXME: required. why?
{-# LANGUAGE KindSignatures #-}

-- The entry point for parsing an ExtOpenScad program.
module Graphics.Implicit.ExtOpenScad.Parser.Statement (parseProgram) where

import Prelude(Char, Either, String, Maybe(Just, Nothing), Monad, return, fmap, ($), (>>), Bool(False, True), map)

import Text.ParserCombinators.Parsec (try, sepBy, sourceLine, GenParser, oneOf, space, char, getPosition, parse, many1, eof, string, SourceName, ParseError, many, noneOf, Line, (<|>), (<?>))

import Text.Parsec.Prim (ParsecT)

import Data.Functor.Identity(Identity)

import Graphics.Implicit.ExtOpenScad.Definitions (Pattern(Name), Statement(DoNothing, NewModule, Include, Echo, If, For, ModuleCall,(:=)),Expr(LamE), StatementI(StatementI))
import Graphics.Implicit.ExtOpenScad.Parser.Util (genSpace, tryMany, stringGS, (*<|>), (?:), patternMatcher, variableSymb)

-- the top level of the expression parser.
import Graphics.Implicit.ExtOpenScad.Parser.Expr (expr0)

parseProgram :: String -> Either ParseError [StatementI]
parseProgram = parse program "" where -- "" is our program name.
    program :: ParsecT String u Identity [StatementI]
    program = do
        sts <- many1 computation
        eof
        return sts

-- | A computable block of code in our openscad-like programming language.
computation :: GenParser Char st StatementI
computation =
    do -- suite statements: no semicolon...
        _ <- genSpace
        s <- tryMany [
            ifStatementI,
            forStatementI,
            throwAway,
            userModuleDeclaration
            ]
        _ <- genSpace
        return s
    *<|> do -- Non suite statements. Semicolon needed...
        _ <- genSpace
        s <- tryMany [
            echo,
            include, -- also handles use
            function,
            assignment
            ]
        _ <- stringGS " ; "
        return s
    *<|> do -- Modules. no semicolon...
        _ <- genSpace
        s <- userModule
        _ <- genSpace
        return s

{-
-- | A suite of s!
--   What's a suite? Consider:
--
--      union() {
--         sphere(3);
--      }
--
--  The suite was in the braces ({}). Similarily, the
--  following has the same suite:
--
--      union() sphere(3);
--
--  We consider it to be a list of computables which
--  are in turn StatementI s.
-}
suite :: GenParser Char st [StatementI]
suite = (fmap return computation <|> do
    _ <- char '{'
    _ <- genSpace
    stmts <- many (try computation)
    _ <- genSpace
    _ <- char '}'
    return stmts
    ) <?> " suite"

-- commenting out a comuptation: use % or * before the statement, and it will not be run.
throwAway :: GenParser Char st StatementI
throwAway = do
    line <- lineNumber
    _ <- genSpace
    _ <- oneOf "%*"
    _ <- genSpace
    _ <- computation
    return $ StatementI line DoNothing

-- An include! Basically, inject another openscad file here...
include :: GenParser Char st StatementI
include = (do
    line <- lineNumber
    injectVals <-  (string "include" >> return True )
               <|> (string "use"     >> return False)
    _ <- stringGS " < "
    filename <- many (noneOf "<> ")
    _ <- stringGS " > "
    return $ StatementI line $ Include filename injectVals
    ) <?> "include "

-- | An assignment (parser)
assignment :: GenParser Char st StatementI
assignment = ("assignment " ?:) $
    do
        line <- lineNumber
        lvalue <- patternMatcher
        _ <- stringGS " = "
        valExpr <- expr0
        return $ StatementI line $ lvalue := valExpr

-- | A function declaration (parser)
function :: GenParser Char st StatementI
function = ("function " ?:) $
    do
        line <- lineNumber
        varSymb <- string "function" >> space >> genSpace >> variableSymb
        _ <- stringGS " ( "
        argVars <- sepBy patternMatcher (stringGS " , ")
        _ <- stringGS " ) = "
        valExpr <- expr0
        return $ StatementI line $ Name varSymb := LamE argVars valExpr

-- | An echo (parser)
echo :: GenParser Char st StatementI
echo = do
    line <- lineNumber
    _ <- stringGS "echo ( "
    exprs <- expr0 `sepBy` stringGS " , "
    _ <- stringGS " ) "
    return $ StatementI line $ Echo exprs

ifStatementI :: GenParser Char st StatementI
ifStatementI =
    "if " ?: do
        line <- lineNumber
        _ <- stringGS "if ( "
        bexpr <- expr0
        _ <- stringGS " ) "
        sTrueCase <- suite
        _ <- genSpace
        sFalseCase <- (stringGS "else " >> suite ) *<|> return []
        return $ StatementI line $ If bexpr sTrueCase sFalseCase

forStatementI :: GenParser Char st StatementI
forStatementI =
    "for " ?: do
        line <- lineNumber
        -- a for loop is of the form:
        --      for ( vsymb = vexpr   ) loops
        -- eg.  for ( a     = [1,2,3] ) {echo(a);   echo "lol";}
        -- eg.  for ( [a,b] = [[1,2]] ) {echo(a+b); echo "lol";}
        _ <- stringGS "for ( "
        lvalue <- patternMatcher
        _ <- stringGS " = "
        vexpr <- expr0
        _ <- stringGS " ) "
        loopContent <- suite
        return $ StatementI line $ For lvalue vexpr loopContent

-- parse a call to a module.
userModule :: GenParser Char st StatementI
userModule = do
    line <- lineNumber
    name <- variableSymb
    _ <- genSpace
    args <- moduleArgsUnit
    _ <- genSpace
    s <- suite *<|> (stringGS " ; " >> return [])
    return $ StatementI line $ ModuleCall name args s

-- declare a module.
userModuleDeclaration :: GenParser Char st StatementI
userModuleDeclaration = do
    line <- lineNumber
    _ <- stringGS "module "
    newModuleName <- variableSymb
    _ <- genSpace
    args <- moduleArgsUnitDecl
    _ <- genSpace
    s <- suite
    return $ StatementI line $ NewModule newModuleName args s

-- parse the arguments passed to a module.
moduleArgsUnit :: GenParser Char st [(Maybe String, Expr)]
moduleArgsUnit = do
    _ <- stringGS " ( "
    args <- sepBy (
        do
            -- eg. a = 12
            symb <- variableSymb
            _ <- stringGS " = "
            expr <- expr0
            return (Just symb, expr)
        *<|> do
            -- eg. a(x,y) = 12
            symb <- variableSymb
            _ <- stringGS " ( "
            argVars <- sepBy variableSymb (try $ stringGS " , ")
            _ <- stringGS " ) = "
            expr <- expr0
            return (Just symb, LamE (map Name argVars) expr)
        *<|> do
            -- eg. 12
            expr <- expr0
            return (Nothing, expr)
        ) (try $ stringGS " , ")
    _ <- stringGS " ) "
    return args

-- parse the arguments in the module declaration.
moduleArgsUnitDecl ::  GenParser Char st [(String, Maybe Expr)]
moduleArgsUnitDecl = do
    _ <- stringGS " ( "
    argTemplate <- sepBy (
        do
            symb <- variableSymb;
            _ <- stringGS " = "
            expr <- expr0
            return (symb, Just expr)
        *<|> do
            symb <- variableSymb;
            _ <- stringGS " ( "
                 -- FIXME: why match this content, then drop it?
            _ <- sepBy variableSymb (try $ stringGS " , ")
            _ <- stringGS " ) = "
            expr <- expr0
            return (symb, Just expr)
        *<|> do
            symb <- variableSymb
            return (symb, Nothing)
        ) (try $ stringGS " , ")
    _ <- stringGS " ) "
    return argTemplate

-- find the line number. used when generating errors.
lineNumber :: forall s u (m :: * -> *).
              Monad m => ParsecT s u m Line
lineNumber = fmap sourceLine getPosition

--FIXME: use the below function to improve error reporting.
{-
-- find the column number. SHOULD be used when generating errors.
columnNumber :: forall s u (m :: * -> *).
              Monad m => ParsecT s u m Column
columnNumber = fmap sourceColumn getPosition
-}
