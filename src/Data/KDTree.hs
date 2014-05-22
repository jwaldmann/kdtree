{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Data.KDTree where


import qualified Data.Vector.Generic  as G
import qualified Data.List            as L


import Data.Function

import Linear

import Control.DeepSeq

import Data.Functor.Foldable

--------------------------------------------------

class KDCompare a where
  data Key a :: *

  kSucc :: Key a -> Key a
  kFirst :: Key a

  dimDistance  :: Key a -> a -> a -> Double
  realDistance :: a -> a -> Double


--------------------------------------------------

instance (Real a, Floating a) => KDCompare (V3 a) where

  data Key (V3 a) = V3X | V3Y | V3Z deriving (Show, Enum)

  kSucc k = case k of V3X -> V3Y; V3Y -> V3Z; V3Z -> V3X
  kFirst = V3X

  dimDistance k (V3 ax ay az) (V3 bx by bz) = realToFrac $ case k of
                                                V3X -> ax - bx
                                                V3Y -> ay - by
                                                V3Z -> az - bz
  realDistance a b = realToFrac $ distance a b



--------------------------------------------------

-- | define a kd tree
--   planes are seperated by point + normal
data KDTree v a = Node (Key a) a (KDTree v a) (KDTree v a)
                | Leaf (Key a) (v a)


-- | define the fix point variant of KDTree
data KDTreeF v a f = NodeF (Key a) a f f
                   | LeafF (Key a) (v a)
  deriving (Functor)


-- implement Base, Foldable and Unfoldable for KDTree
type instance Base (KDTree v a) = KDTreeF v a

instance Foldable (KDTree v a) where
  project (Leaf d a)     = LeafF d a
  project (Node d p l r) = NodeF d p l r

instance Unfoldable (KDTree v a) where
  embed (LeafF d a)     = Leaf d a
  embed (NodeF d p l r) = Node d p l r

---

instance (NFData (v a), NFData a) => NFData (KDTree v a) where
  rnf (Leaf _ vs)    = rnf vs
  rnf (Node _ _ l r) = rnf l `seq` rnf r `seq` ()

--------------------------------------------------

newtype BucketSize = BucketSize {unMinBucket :: Int}
  deriving (Eq,Ord,Show,Read,Num)

--------------------------------------------------

empty :: (KDCompare a, G.Vector v a) => KDTree v a
empty = Leaf kFirst G.empty

singleton :: (KDCompare a, G.Vector v a) => a -> KDTree v a
singleton x = Leaf kFirst (G.singleton x)

--------------------------------------------------

-- FIXME split leaf

insert :: (KDCompare a, G.Vector v a) => BucketSize -> a -> KDTree v a -> KDTree v a
insert _  x (Leaf d xs)    = Leaf d (x `G.cons` xs)
insert mb x (Node d p l r) | dimDistance d p x < 0 = Node d p (insert mb x l) r
                           | otherwise             = Node d p l (insert mb x r)

--------------------------------------------------

kdtree :: (KDCompare a, G.Vector v a) => BucketSize -> v a -> KDTree v a
kdtree mb vs = ana (kdtreeF mb) (kFirst,vs)

kdtreeF :: (KDCompare a, G.Vector v a)
          => BucketSize -> (Key a,v a) -> KDTreeF v a (Key a,v a)
kdtreeF (BucketSize mb) = go
  where go (k,fs) | G.length fs <= mb = LeafF k (G.convert fs)
                  | otherwise         = NodeF k (G.head r) (kSucc k,l) (kSucc k,r)
                    where (l,r) = splitBuckets k fs

{-# INLINE kdtreeF #-}

splitBuckets :: (KDCompare a, G.Vector v a)
             => Key a -> v a -> (v a, v a)
splitBuckets dim vs = G.splitAt (G.length vs `quot` 2)
                    . G.fromListN (G.length vs)
                    . L.sortBy (compare `on` dimDistance dim (G.head vs))
                    $ G.toList vs

{-# INLINE splitBuckets #-}

--------------------------------------------------


-- | get all points in the tree, sorted by distance to the 'q'uery point
-- | this is the 'bread and butter' function and should be quite fast
nearestNeighbors :: (KDCompare a, G.Vector v a) => a -> KDTree v a -> [a]
nearestNeighbors q = cata (nearestNeighborsF q)

nearestNeighborsF :: (KDCompare a, G.Vector v a) => a -> KDTreeF v a [a] -> [a]
nearestNeighborsF q (LeafF _ vs)    = L.sortBy (compare `on` realDistance q) . G.toList $ vs
nearestNeighborsF q (NodeF d p l r) = if x < 0 then go l r else go r l

  where x   = dimDistance d p q
        go  = mergeBuckets x q

        {-# INLINE go #-}
        {-# INLINE x  #-}

{-# INLINE nearestNeighborsF #-}

-- recursively merge the two children
-- the second line makes sure that points in the
-- 'safe' region are prefered
mergeBuckets :: (KDCompare a) => Double -> a -> [a] -> [a] -> [a]
mergeBuckets d q = go
  where rdq = realDistance q
        go []     bs                     = bs
        go (a:as) bs     | rdq a < d     = a : go as bs
        go as     []                     = as
        go (a:as) (b:bs) | rdq a < rdq b = a : go as (b:bs)
                         | otherwise     = b : go (a:as) bs

{-# INLINE mergeBuckets #-}

--------------------------------------------------

-- | get the nearest neighbor of point q
nearestNeighbor :: (KDCompare a, G.Vector v a) => a -> KDTree v a -> [a]
nearestNeighbor q = take 1 . nearestNeighbors q

----------------------------------------------------

-- | return the points around a 'q'uery point up to radius 'r'
pointsAround :: (KDCompare a, G.Vector v a) => Double -> a -> KDTree v a -> [a]
pointsAround r q = takeWhile (\p -> realDistance q p < abs r) . nearestNeighbors q

--------------------------------------------------

