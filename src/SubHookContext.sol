// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

struct SubHookContext {
    // accumulated delta on specified token
    int128 deltaSpecified;
    // accumulated delta on unspecified token
    int128 deltaUnspecified;
    // arbitrary data
    bytes hookData;
    // hook data coming from the user
    bytes originalHookData;
    // if true skip remaining sub-hooks
    bool halt;
}
