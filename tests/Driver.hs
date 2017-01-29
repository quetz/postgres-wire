module Driver where

import Data.Monoid ((<>))
import Data.Foldable
import Control.Monad
import Data.Either
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BS
import qualified Data.Vector as V

import Test.Tasty
import Test.Tasty.HUnit

import Database.PostgreSQL.Driver.Connection
import Database.PostgreSQL.Protocol.Types

import Connection

testDriver :: TestTree
testDriver = testGroup "Driver"
    [ testCase "Single batch" testBatch
    , testCase "Two batches" testTwoBatches
    , testCase "Empty query" testEmptyQuery
    , testCase "Query without result" testQueryWithoutResult
    , testCase "Invalid queries" testInvalidBatch
    , testCase "Describe statement" testDescribeStatement
    , testCase "Describe statement with no data" testDescribeStatementNoData
    , testCase "Describe empty statement" testDescribeStatementEmpty
    ]

makeQuery1 :: B.ByteString -> Query
makeQuery1 n = Query "SELECT $1" [Oid 23] [n] Text Text

makeQuery2 :: B.ByteString -> B.ByteString -> Query
makeQuery2 n1 n2 = Query "SELECT $1 + $2" [Oid 23, Oid 23] [n1, n2] Text Text

fromRight :: Either e a -> a
fromRight (Right v) = v
fromRight _         = error "fromRight"


testBatch :: IO ()
testBatch = withConnection $ \c -> do
    let a = "5"
        b = "3"
    sendBatchAndSync c [makeQuery1 a, makeQuery1 b]
    readReadyForQuery c

    r1 <- readNextData c
    r2 <- readNextData c
    DataMessage [[a]] @=? fromRight r1
    DataMessage [[b]] @=? fromRight r2

testTwoBatches :: IO ()
testTwoBatches = withConnection $ \c -> do
    let a = 7
        b = 2
    sendBatchAndFlush c [ makeQuery1 (BS.pack (show a))
                        , makeQuery1 (BS.pack (show b))]
    r1 <- fromMessage . fromRight <$> readNextData c
    r2 <- fromMessage . fromRight <$> readNextData c

    sendBatchAndSync c [makeQuery2 r1 r2]
    r <- readNextData c
    readReadyForQuery c

    DataMessage [[BS.pack (show $ a + b)]] @=? fromRight r
  where
    fromMessage (DataMessage [[v]]) = v
    fromMessage _                   = error "from message"

testEmptyQuery :: IO ()
testEmptyQuery = assertQueryNoData $
    Query "" [] [] Text Text

testQueryWithoutResult :: IO ()
testQueryWithoutResult = assertQueryNoData $
    Query "SET client_encoding TO UTF8" [] [] Text Text

-- helper
assertQueryNoData :: Query -> IO ()
assertQueryNoData q = withConnection $ \c -> do
    sendBatchAndSync c [q]
    r <- fromRight <$> readNextData c
    readReadyForQuery c
    DataMessage [] @=? r

-- | Asserts that all the received data rows are in form (Right _)
checkRightResult :: Connection -> Int -> Assertion
checkRightResult conn 0 = pure ()
checkRightResult conn n = readNextData conn >>=
    either (const $ assertFailure "Result is invalid")
           (const $ checkRightResult conn (n - 1))

-- | Asserts that (Left _) as result exists in the received data rows.
checkInvalidResult :: Connection -> Int -> Assertion
checkInvalidResult conn 0 = assertFailure "Result is right"
checkInvalidResult conn n = readNextData conn >>=
    either (const $ pure ())
           (const $ checkInvalidResult conn (n -1))

testInvalidBatch :: IO ()
testInvalidBatch = do
    let rightQuery = makeQuery1 "5"
        q1 = Query "SEL $1" [Oid 23] ["5"] Text Text
        q2 = Query "SELECT $1" [Oid 23] ["a"] Text Text
        q3 = Query "SELECT $1" [Oid 23] [] Text Text
        q4 = Query "SELECT $1" [] ["5"] Text Text

    assertInvalidBatch "Parse error" [q1]
    assertInvalidBatch "Invalid param" [ q2]
    assertInvalidBatch "Missed param" [ q3]
    assertInvalidBatch "Missed oid of param" [ q4]
    assertInvalidBatch "Parse error" [rightQuery, q1]
    assertInvalidBatch "Invalid param" [rightQuery, q2]
    assertInvalidBatch "Missed param" [rightQuery, q3]
    assertInvalidBatch "Missed oid of param" [rightQuery, q4]
  where
    assertInvalidBatch desc qs = withConnection $ \c -> do
        sendBatchAndSync c qs
        readReadyForQuery c
        checkInvalidResult c $ length qs

testDescribeStatement :: IO ()
testDescribeStatement = withConnection $ \c -> do
    r <- describeStatement c $
               "select typname, typnamespace, typowner, typlen, typbyval,"
            <> "typcategory, typispreferred, typisdefined, typdelim, typrelid,"
            <> "typelem, typarray from pg_type where typtypmod = $1 "
            <> "and typisdefined = $2"
    assertBool "Should be Right" $ isRight r

testDescribeStatementNoData :: IO ()
testDescribeStatementNoData = withConnection $ \c -> do
    r <- fromRight <$> describeStatement c "SET client_encoding TO UTF8"
    assertBool "Should be empty" $ V.null (fst r)
    assertBool "Should be empty" $ V.null (snd r)

testDescribeStatementEmpty :: IO ()
testDescribeStatementEmpty = withConnection $ \c -> do
    r <- fromRight <$> describeStatement c ""
    assertBool "Should be empty" $ V.null (fst r)
    assertBool "Should be empty" $ V.null (snd r)
