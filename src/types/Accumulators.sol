// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

struct BeforeSwapAccumulator {
    int128[] deltaSpecifieds;
    int128[] deltaUnspecifieds;
    uint24[] lpFeeOverrides;
}

struct AfterSwapAccumulator {
    int128[] deltaSpecifieds;
    int128[] deltaUnspecifieds;
}

struct LiquidityAccumulator {
    int128[] deltaSpecifieds;
    int128[] deltaUnspecifieds;
}
