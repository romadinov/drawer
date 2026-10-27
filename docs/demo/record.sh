#!/bin/bash
# Records the iPad demo: clean simulator, screen recording, scripted UI test.
D=/private/tmp/claude-501/-Users-alexeyromadinov-Dev-drawer/3efdac81-7b12-4e37-b838-9c0d1f0ac19b/scratchpad/demo
DEV=9D3C323C-2AA8-4FA4-9D01-48B6CC54C98B
cd /Users/alexeyromadinov/Dev/drawer
xcrun simctl boot $DEV 2>/dev/null; sleep 3
xcrun simctl uninstall $DEV com.romadinov.drawer.mobile 2>/dev/null
xcrun simctl status_bar $DEV override --time 9:41 --batteryLevel 100 --batteryState charged 2>/dev/null
rm -f $D/scenes.txt $D/rec.mp4
xcrun simctl io $DEV recordVideo --codec=h264 --force $D/rec.mp4 2> $D/rec.log &
REC=$!
until grep -q "Recording started" $D/rec.log 2>/dev/null; do sleep 0.1; done
python3 -c 'import time; print(time.time())' > $D/rec_start.txt
TEST_RUNNER_DEMO_DIR=$D xcodebuild -project Drawer.xcodeproj -scheme DrawerMobile \
  -destination "platform=iOS Simulator,id=$DEV" -derivedDataPath build \
  test-without-building -only-testing:DrawerMobileUITests/DemoTests/testDemo > $D/test.log 2>&1
sleep 1
kill -INT $REC; wait $REC
grep -E "DemoTests.swift:[0-9]+|passed \(|failed \(" $D/test.log
cat $D/scenes.txt
