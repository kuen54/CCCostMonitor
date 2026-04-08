#!/bin/bash
sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap.bak
echo "Done! Checking..."
ls /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap 2>&1 && echo "FAIL: file still exists" || echo "OK: file removed"
