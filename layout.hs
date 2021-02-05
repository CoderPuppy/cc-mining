{-# OPTIONS_GHC -Wno-tabs #-}
{-# LANGUAGE RecordWildCards #-}

module Layout where

import qualified Data.Set as S
import Control.Arrow
import Data.List
import Data.Traversable
import Data.Foldable
import Control.Applicative
import Control.Monad

type Coord = (Int, Int)
type Dir = Coord -- x² + y² = 1
type Cost = Int
type Move = ((Coord, Dir), Cost)
data StPos = StPos {
	pos :: Coord,
	dir :: Dir,
	cost :: Cost
} deriving (Show)
data StBoard = StBoard {
	visited :: S.Set Coord,
	minX :: Int, minY :: Int,
	maxX :: Int, maxY :: Int
} deriving (Show)

initialPos :: StPos
initialPos = StPos {
		pos = (0, 0),
		dir = (1, 0),
		cost = 0
	}
initialBoard :: StPos -> StBoard
initialBoard (StPos {..}) = StBoard {
		visited = S.singleton pos,
		minX = 0, minY = 0,
		maxX = 0, maxY = 0
	}

rotate :: Dir -> Coord -> Coord
rotate (dx, dy) (x, y) = (x * dx + y * negate dy, x * dy + y * dx)

visit :: Coord -> StBoard -> StBoard
visit p@(x, y) (StBoard {..}) = StBoard {
		visited = S.insert p visited,
		minX = min minX x, minY = min minY y,
		maxX = max maxX x, maxY = max maxY y
	}

moves :: [((Coord, Dir), Cost)]
moves = sortOn snd $ [
		(((2, 1), (0, 1)), 4),
		(((1, -2), (0, -1)), 4),

		(((3, -1), (0, -1)), 5),
		(((1, 3), (0, 1)), 5),

		(((5, 0), (1, 0)), 5),

		(((4, 2), (0, 1)), 7),
		(((4, -3), (0, -1)), 8)
	] >>= \((off, rot), cost) -> [
			((off, rot), cost),
			((rotate (0, 1) off, rotate (0, 1) rot), cost + 1),
			((rotate (0, -1) off, rotate (0, -1) rot), cost + 1),
			((rotate (-1, 0) off, rotate (-1, 0) rot), cost + 2)
		]

applyMove :: Move -> StPos -> StPos
applyMove ((off, rot), mc) (StPos {..}) = StPos {
		pos = (uncurry (+) *** uncurry (+)) (pos, rotate dir off),
		dir = rotate dir rot,
		cost = cost + mc
	}

invertMove :: Move -> Move
invertMove (((ox, oy), (rx, ry)), cost) = ((rotate ir (-ox, -oy), ir), cost)
	where ir = (rx, -ry)

continue :: (StPos, StBoard) -> [(StPos, StBoard)]
continue (st_pos, st_board) = do
	move <- moves
	let st_pos' = applyMove move st_pos
	guard $ S.notMember (pos st_pos') (visited st_board)
	let st_board' = visit (pos st_pos') st_board
	pure (st_pos', st_board')

isPossible :: StBoard -> Bool
isPossible (StBoard {..}) = (maxX - minX + 1) <= 16 && (maxY - minY + 1) <= 16

isValid :: StBoard -> Bool
isValid (StBoard {..}) = all (flip S.member visited) $ do
	x <- [minX..maxX]
	y <- [minY..maxY]
	guard $ (x + 3 * y) `mod` 5 == 0
	pure (x, y)

test :: (StPos, StBoard) -> [(StPos, StBoard)]
test st = case filter (isPossible . snd) $ continue st of
	[] -> pure st
	nexts -> nexts >>= test

test2 :: (StPos, StBoard) -> [(StPos, StBoard)]
test2 st = st:(filter (isPossible . snd) (continue st) >>= test2)

-- `filter (isValid . snd) $ test (initialPos, initialBoard initialPos)` never produced anything
