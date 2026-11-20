#!/usr/bin/env swift
// Sends a command to a running DEBUG build of Lidless (ignored by Release builds).
// usage: scripts/debug-command.swift fan-max|fan-auto|fan-custom:<rpm>|lid-on|lid-off|install-helper|keep-awake-on|keep-awake-off|status
import Foundation
let cmd = CommandLine.arguments.dropFirst().first ?? "status"
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("dev.lidless.debug.command"), object: cmd, userInfo: nil, deliverImmediately: true)
print("sent: \(cmd)")
