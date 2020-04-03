module Test.Spec.Contracts.SuperRareLegacy where

import Prelude
import Chanterelle.Test (buildTestConfig)
import Data.Array (filter, (..))
import Data.Array.Partial (head)
import Data.Either (isLeft)
import Data.Maybe (Maybe(..), maybe)
import Data.Traversable (for)
import Deploy.Contracts.SuperRareLegacy (SuperRareLegacy)
import Deploy.Contracts.SuperRareLegacy (deployScript) as SuperRareLegacy
import Effect.Aff (Aff, try)
import Effect.Class.Console (logShow)
import Network.Ethereum.Web3 (embed)
import Partial.Unsafe (unsafePartial)
import Record as Record
import Test.Spec (SpecT, beforeAll, describe, describeOnly, it, pending)
import Test.Spec.Assertions (shouldEqual, shouldNotSatisfy, shouldSatisfy)
import Test.Spec.Contracts.SupeRare as SupeRare
import Test.Spec.Contracts.SupeRare as SupeRareSpec
import Test.Spec.Contracts.SuperRareLegacy.Actions (TestEnv, isApprovedForAll, isUpgraded, ownerOf, preUpgradeOwnerOf, refreshPreUpgradeOwnerOf, setApprovalForAll, tokenCreator, totalSupply, transferFrom)
import Test.Spec.Contracts.Utils (createTokensWithFunction, intToUInt256, nullAddress, uInt256FromBigNumber, web3Test)

spec :: SpecT Aff Unit Aff Unit
spec =
  beforeAll (init Nothing) do
    describeOnly "SuperRareLegacy"
      $ do
          it "should have correct total supply" \tenv@{ provider } ->
            web3Test provider do
              let
                { numOldSuperRareTokens } = tenv
              supply <- totalSupply tenv
              supply `shouldEqual` intToUInt256 numOldSuperRareTokens
          it "should have correct pre-upgrade token owners" \tenv@{ provider } ->
            web3Test provider do
              let
                { numOldSuperRareTokens } = tenv
              void
                $ for (1 .. numOldSuperRareTokens) \tid -> do
                    owner <- SupeRare.ownerOf tenv (intToUInt256 tid)
                    preUpgradeOwner <- preUpgradeOwnerOf tenv (intToUInt256 tid)
                    owner `shouldEqual` preUpgradeOwner
          it "should return false when calling `isUpgraded` on non-upgraded token" \tenv@{ provider } -> do
            web3Test provider do
              let
                { numOldSuperRareTokens } = tenv
              void
                $ for (1 .. numOldSuperRareTokens) \tid -> do
                    upgraded <- isUpgraded tenv (intToUInt256 tid)
                    upgraded `shouldEqual` false
          it "should get null address as token's owner if not upgraded" \tenv@{ provider } -> do
            web3Test provider do
              let
                { numOldSuperRareTokens } = tenv
              void
                $ for (1 .. 1) \tid -> do
                    owner <- ownerOf tenv (intToUInt256 tid)
                    owner `shouldEqual` nullAddress
          it "should fail to refresh a pre-upgrade owner when it needs no refreshing" \tenv@{ provider } -> do
            res <-
              try
                $ web3Test provider do
                    let
                      { numOldSuperRareTokens } = tenv
                    void
                      $ for (1 .. 1) \tid -> do
                          void $ refreshPreUpgradeOwnerOf tenv (intToUInt256 tid)
            res `shouldSatisfy` isLeft
          it "should refresh a pre-upgrade owner" \tenv@{ provider } ->
            web3Test provider do
              let
                { numOldSuperRareTokens, accounts } = tenv
              void
                $ for (1 .. 1) \tid -> do
                    owner <- SupeRare.ownerOf tenv (intToUInt256 tid)
                    let
                      to = unsafePartial head $ filter (\addr -> addr /= owner) accounts
                    void $ SupeRare.transfer tenv owner to $ intToUInt256 tid
                    void $ refreshPreUpgradeOwnerOf tenv $ intToUInt256 tid
                    preUpgradeOwner <- preUpgradeOwnerOf tenv (intToUInt256 tid)
                    to `shouldEqual` preUpgradeOwner
          it "should upgrade a token" \tenv@{ provider } ->
            web3Test provider do
              let
                { accounts, superRareLegacy: { deployAddress: legacyAddr } } = tenv
              void
                $ for (1 .. 2) \tid -> do
                    owner <- SupeRare.ownerOf tenv (intToUInt256 tid)
                    let
                      to = unsafePartial head $ filter (\addr -> addr /= owner) accounts
                    void $ SupeRare.transfer tenv owner legacyAddr $ intToUInt256 tid
                    upgraded <- isUpgraded tenv (intToUInt256 tid)
                    upgraded `shouldEqual` true
          it "should find the correct creator for an upgraded token" \tenv@{ provider } ->
            web3Test provider do
              let
                { accounts } = tenv
              void
                $ for (1 .. 2) \tid -> do
                    srCreator <- SupeRare.creatorOfToken tenv (intToUInt256 tid)
                    srlCreator <- tokenCreator tenv (intToUInt256 tid)
                    srlCreator `shouldEqual` srCreator
          it "should find the upgraded tokens as upgraded" \tenv@{ provider } ->
            web3Test provider
              $ void
              $ for (1 .. 2) \tid -> do
                  upgraded <- isUpgraded tenv (intToUInt256 tid)
                  upgraded `shouldEqual` true
          it "can approve others to manage tokens" \tenv@{ provider, accounts } -> do
            web3Test provider
              $ void
              $ for (1 .. 2) \tid -> do
                  owner <- ownerOf tenv (intToUInt256 tid)
                  let
                    approvedOperator = unsafePartial head $ filter ((/=) owner) accounts
                  void $ setApprovalForAll tenv owner approvedOperator true
                  approved <- isApprovedForAll tenv owner approvedOperator
                  approved `shouldEqual` true
                  void
                    $ transferFrom tenv owner approvedOperator (intToUInt256 tid)
                  newOwner <- ownerOf tenv (intToUInt256 tid)
                  newOwner `shouldEqual` approvedOperator

-----------------------------------------------------------------------------
-- | Init
-----------------------------------------------------------------------------
init :: Maybe (SupeRare.TestEnv ()) -> Aff (TestEnv ())
init mtenv = do
  tenv@{ provider, supeRare: { deployAddress: supeRare } } <-
    maybe initSupeRare pure mtenv
  let
    numOldSuperRareTokens = 5
  web3Test provider $ createOldSupeRareTokens tenv numOldSuperRareTokens
  { superRareLegacy } <-
    buildTestConfig "http://localhost:8545" 60
      ( SuperRareLegacy.deployScript
          ((1 .. numOldSuperRareTokens) <#> intToUInt256)
          { _name: "SupeRareLegacy"
          , _symbol: "SUPR"
          , _oldSuperRare: supeRare
          }
      )
  pure $ Record.merge { superRareLegacy, numOldSuperRareTokens } tenv
  where
  initSupeRare = do
    tenv@{ accounts, provider } <- SupeRareSpec.init
    web3Test provider $ whitelistAddresses tenv
    pure tenv

  createOldSupeRareTokens tenv n = void $ createTokensWithFunction tenv n (SupeRare.addNewToken tenv)

  whitelistAddresses tenv@{ accounts } = void $ for accounts (SupeRareSpec.whitelistAddress tenv)
