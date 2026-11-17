{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Yamaarashi.Flow.PathDiscovery
-- Description : Dynamic workspace and toolchain path resolution
--
-- Dynamically locates workspace directories (plans, sibling repositories,
-- seeds, pending/completed task queues) and toolchain executables without
-- hardcoded filesystem paths.
module Yamaarashi.Flow.PathDiscovery
  ( getPlansDir
  , getSrcDir
  , resolveRepoDir
  , findHlsAutoheal
  , getCompletedQueueDir
  , getPendingQueueDir
  , getSeedsDir
  ) where

import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , findExecutable
  , getCurrentDirectory
  , getHomeDirectory
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeDirectory)

-- | Discover the plans repository/directory.
--
-- Hierarchy:
-- 1. 'PLANS_ROOT' or 'PLANS_DIR' environment variables
-- 2. Current working directory if it contains 'tier2-yamaarashi' or 'PLAN.md'
-- 3. User home directory: @~/src/plans@
-- 4. Fallback: @/home/nyc/src/plans@
getPlansDir :: IO FilePath
getPlansDir = do
  mEnv1 <- lookupEnv "PLANS_ROOT"
  mEnv2 <- lookupEnv "PLANS_DIR"
  case mEnv1 of
    Just p | not (null p) -> pure p
    _ -> case mEnv2 of
      Just p | not (null p) -> pure p
      _ -> do
        cwd <- getCurrentDirectory
        hasTier2 <- doesDirectoryExist (cwd </> "tier2-yamaarashi")
        hasPlanMd <- doesFileExist (cwd </> "PLAN.md")
        if hasTier2 || hasPlanMd
          then pure cwd
          else do
            home <- getHomeDirectory
            let homePlans = home </> "src" </> "plans"
            eHomePlans <- doesDirectoryExist homePlans
            if eHomePlans
              then pure homePlans
              else pure "/home/nyc/src/plans"

-- | Get the parent src directory containing multi-repo checkouts (e.g. ~/src).
getSrcDir :: IO FilePath
getSrcDir = do
  mSrcEnv <- lookupEnv "SRC_ROOT"
  case mSrcEnv of
    Just s | not (null s) -> pure s
    _ -> do
      plansDir <- getPlansDir
      let parentSrc = takeDirectory plansDir
      eParent <- doesDirectoryExist parentSrc
      if eParent
        then pure parentSrc
        else do
          home <- getHomeDirectory
          pure (home </> "src")

-- | Resolve target repository path by name (e.g. "smirk", "gargamelle", "penelope", "sarutahiko").
resolveRepoDir :: String -> IO FilePath
resolveRepoDir repoName = do
  srcDir <- getSrcDir
  let candidate = srcDir </> repoName
  exists <- doesDirectoryExist candidate
  if exists
    then pure candidate
    else pure ("/home/nyc/src" </> repoName)

-- | Locate the hls-autoheal binary dynamically.
--
-- Checks:
-- 1. @PATH@ search via 'findExecutable'
-- 2. @~/.local/bin/hls-autoheal@
-- 3. @/home/nyc/.local/bin/hls-autoheal@
findHlsAutoheal :: IO (Maybe FilePath)
findHlsAutoheal = do
  mInPath <- findExecutable "hls-autoheal"
  case mInPath of
    Just p -> pure (Just p)
    Nothing -> do
      home <- getHomeDirectory
      let homeBin = home </> ".local" </> "bin" </> "hls-autoheal"
      eHomeBin <- doesFileExist homeBin
      if eHomeBin
        then pure (Just homeBin)
        else do
          let fallback = "/home/nyc/.local/bin/hls-autoheal"
          eFallback <- doesFileExist fallback
          if eFallback then pure (Just fallback) else pure Nothing

-- | Get the pending queue directory for Tier-2 task packets.
getPendingQueueDir :: IO FilePath
getPendingQueueDir = do
  plans <- getPlansDir
  pure (plans </> "tier2-yamaarashi" </> "pending")

-- | Get the completed queue directory for Tier-2 task packets.
getCompletedQueueDir :: IO FilePath
getCompletedQueueDir = do
  plans <- getPlansDir
  pure (plans </> "tier2-yamaarashi" </> "completed")

-- | Get the seed files directory.
getSeedsDir :: IO FilePath
getSeedsDir = do
  plans <- getPlansDir
  pure (plans </> "seeds")
