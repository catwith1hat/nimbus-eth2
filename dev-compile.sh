#!/bin/sh
./env.sh nim c -d:release -d:disableLTO -d:libp2p_agents_metrics -d:KnownLibP2PAgents=nimbus,lighthouse,lodestar,prysm,teku,grandine --parallelBuild:0 -o:build/nimbus_beacon_node beacon_chain/nimbus_beacon_node.nim
