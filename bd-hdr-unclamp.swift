// bd-hdr-unclamp.swift — keep a BetterDisplay-managed HDR display usable for HDR content.
//
// PROBLEM (meter-measured): with BetterDisplay holding the display's transfer table, HDR
// content is clamped to SDR white whenever brightness > 1.0, gamma != 0 or temperature != 0.
// That is exactly the tuned SDR look. So the look and usable HDR cannot coexist *at the same
// moment*, and the fix is to neutralise those three settings only while fullscreen content is
// on screen, then put the owner's own values back.
//
// This binary: detects fullscreen content on the target display, saves the current values,
// neutralises the three, and restores the SAVED values (not hard-coded ones) afterwards.
// State persists across restarts, so a crash can never leave the display neutralised.
//
// usage: bd-hdr-unclamp [--once] [--dry-run] [--status] [--pause] [--resume]
//   --once      run a single evaluation and exit
//   --dry-run   decide and log, never touch BetterDisplay
//   --status    print current state and pause flag
//   --pause     create the kill switch file (~/.config/bd-hdr-unclamp/pause)
//   --resume    remove it

import AppKit
import CoreGraphics
import Foundation

// MARK: - configuration

let targetScreenName = "AW3425DW"          // matched by NSScreen.localizedName
let pollSeconds: Double = 1.0      // idle poll; 0.25 s once a candidate appears
let graceSeconds: Double = 0.5        // before removing the look (just enough to skip flicker)
let graceExitSeconds: Double = 0.25   // before restoring it
let fastPollSeconds: Double = 0.5
let onceMode = CommandLine.arguments.contains("--once")
let effectiveGraceEnter: Double = onceMode ? 0.0 : graceSeconds
let effectiveGraceExit: Double = onceMode ? 0.0 : graceExitSeconds
let reassertSeconds: Double = 30.0
let bdTimeoutSeconds: Double = 5.0     // a single betterdisplaycli call may never exceed this
let bdPath = "/opt/homebrew/bin/betterdisplaycli"
let stateDir = ("~/.local/state/bd-hdr-unclamp" as NSString).expandingTildeInPath
let configDir = ("~/.config/bd-hdr-unclamp" as NSString).expandingTildeInPath
let pauseFile = configDir + "/pause"
let stateFile = stateDir + "/state.json"
let ignoreFile = configDir + "/ignore"
let logFile = stateDir + "/bd-hdr-unclamp.log"
let logCapBytes = 1_000_000

// MARK: - logging (capped)

func rotateLogIfNeeded() {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: logFile),
          let size = attrs[.size] as? Int, size > logCapBytes else { return }
    try? fm.removeItem(atPath: logFile + ".old")
    try? fm.moveItem(atPath: logFile, toPath: logFile + ".old")
}

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) \(msg)\n"
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    rotateLogIfNeeded()
    if let fh = FileHandle(forWritingAtPath: logFile) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        try? line.write(toFile: logFile, atomically: true, encoding: .utf8)
    }
}

// MARK: - betterdisplaycli

@discardableResult
func bd(_ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bdPath)
    p.arguments = ["-name=\(targetScreenName)"] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "spawn failed") }

    // Read with a deadline. betterdisplaycli has been observed to hang for MINUTES on this
    // machine (the log's "not answering" episodes); a blocking readDataToEndOfFile would wedge
    // the whole poll loop and leave the display neutralised until someone poked it.
    let box = Box()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        box.data = pipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    if group.wait(timeout: .now() + bdTimeoutSeconds) == .timedOut {
        p.terminate()                                   // SIGTERM
        if group.wait(timeout: .now() + 1.0) == .timedOut {
            kill(p.processIdentifier, SIGKILL)          // still stuck: reap it
            _ = group.wait(timeout: .now() + 1.0)
        }
        log("betterdisplaycli \(args.first ?? "") timed out after \(Int(bdTimeoutSeconds))s — killed")
        try? pipe.fileHandleForReading.close()
        return (-2, "timeout")
    }
    p.waitUntilExit()
    return (p.terminationStatus, String(data: box.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
}

final class Box: @unchecked Sendable { var data = Data() }


func bdGet(_ feature: String) -> String? {
    let r = bd(["get", "-\(feature)"])
    guard r.code == 0, !r.out.isEmpty, !r.out.lowercased().contains("failed") else { return nil }
    return r.out.split(separator: "\n").first.map(String.init)
}

@discardableResult
func bdSet(_ pairs: [(String, String)]) -> Bool {
    let args = ["set"] + pairs.map { "-\($0.0)=\($0.1)" }
    return bd(args).code == 0
}

// MARK: - display + fullscreen detection

func targetDisplayID() -> CGDirectDisplayID? {
    for s in NSScreen.screens {
        guard s.localizedName == targetScreenName else { continue }
        if let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDirectDisplayID(num.uint32Value)
        }
    }
    return nil
}

/// True when some normal app window covers the target display.
func ignoredAppNames() -> Set<String> {
    guard let txt = try? String(contentsOfFile: ignoreFile, encoding: .utf8) else { return [] }
    return Set(txt.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                  .filter { !$0.isEmpty && !$0.hasPrefix("#") })
}

func fullscreenOwner() -> String? {
    let ignored = ignoredAppNames()
    guard let dispID = targetDisplayID() else { return nil }
    let bounds = CGDisplayBounds(dispID)
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }

    for w in list {
        guard let b = w[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? Double, let y = b["Y"] as? Double,
              let wd = b["Width"] as? Double, let ht = b["Height"] as? Double else { continue }
        // coverage (window at least covers the display), with a small tolerance
        let covers = x <= bounds.origin.x + 2 && y <= bounds.origin.y + 2 &&
                     x + wd >= bounds.origin.x + bounds.width - 2 &&
                     y + ht >= bounds.origin.y + bounds.height - 2
        guard covers else { continue }
        if let alpha = w[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
        guard let pid = w[kCGWindowOwnerPID as String] as? Int32 else { continue }
        if pid == ProcessInfo.processInfo.processIdentifier { continue }
        // only real foreground apps: excludes WindowServer, Dock, loginwindow, screensaver
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular else { continue }
        let name = app.localizedName ?? "pid \(pid)"
        if ignored.contains(name) { continue }
        return name
    }
    return nil
}

// MARK: - persisted state

struct Saved: Codable { var brightness: String; var gamma: String; var temperature: String }
/// `saved` is the snapshot taken when entering HDR mode; `tuned` is the last known good look and
/// survives the round trip, so a capture taken while the display was ALREADY neutralised can never
/// overwrite the owner's real values with 1.0/0/0.
struct State: Codable { var mode: String; var saved: Saved?; var tuned: Saved? }

let fallbackTuned = Saved(brightness: "1.15", gamma: "-0.34", temperature: "-0.03")

func isNeutral(_ s: Saved) -> Bool {
    func num(_ v: String) -> Double { Double(v.trimmingCharacters(in: .whitespaces)) ?? .nan }
    return abs(num(s.brightness) - 1.0) < 0.001 && abs(num(s.gamma)) < 0.001 && abs(num(s.temperature)) < 0.001
}

func loadState() -> State {
    guard let d = FileManager.default.contents(atPath: stateFile),
          let s = try? JSONDecoder().decode(State.self, from: d) else {
        return State(mode: "tuned", saved: nil, tuned: nil)
    }
    return s
}

func saveState(_ s: State) {
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(s) { try? d.write(to: URL(fileURLWithPath: stateFile)) }
}

func isPaused() -> Bool { FileManager.default.fileExists(atPath: pauseFile) }

// MARK: - actions

let neutral: [(String, String)] = [("brightness", "1.0"), ("gamma", "0"), ("temperature", "0")]

func captureAndNeutralise(dryRun: Bool) -> Saved? {
    guard let b = bdGet("brightness"), let g = bdGet("gamma"), let t = bdGet("temperature") else {
        log("cannot read current values — leaving display alone this tick")
        return nil
    }
    var captured = Saved(brightness: b, gamma: g, temperature: t)
    if isNeutral(captured) {
        // The panel was ALREADY neutral when this transition fired (an earlier run was killed
        // mid-HDR, or a manual experiment left 1.0/0/0). Recording that as "the look" makes every
        // later restore land on a washed-out display, so keep the last known good values.
        captured = state.tuned ?? fallbackTuned
        log("captured neutral values — keeping last tuned look (\(captured.brightness) / \(captured.gamma) / \(captured.temperature))")
    }
    let saved = captured
    if dryRun { log("[dry-run] would neutralise; saved \(saved)"); return saved }
    guard bdSet(neutral) else { log("bd set (neutralise) failed"); return nil }
    log("HDR pass-through active (saved brightness=\(saved.brightness) gamma=\(saved.gamma) temperature=\(saved.temperature))")
    return saved
}

@discardableResult
func restore(_ saved: Saved?, dryRun: Bool) -> Saved {
    let s = saved ?? state.tuned ?? fallbackTuned
    if dryRun { log("[dry-run] would restore \(s)"); return s }
    let ok = bdSet([("brightness", s.brightness), ("gamma", s.gamma), ("temperature", s.temperature)])
    log(ok ? "tuned look restored (\(s.brightness) / \(s.gamma) / \(s.temperature))"
           : "RESTORE FAILED — check BetterDisplay")
    return s
}

func displayIsHDR() -> Bool {
    guard let h = bdGet("hdr") else { return false }
    return h.lowercased().contains("on")
}

// MARK: - main

let args = CommandLine.arguments
let once = args.contains("--once")
let dryRun = args.contains("--dry-run")

if args.contains("--status") {
    let s = loadState()
    print("mode=\(s.mode) paused=\(isPaused()) saved=\(String(describing: s.saved))")
    exit(0)
}
if args.contains("--pause") {
    try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: pauseFile, contents: nil)
    print("paused (watcher will not touch the display)")
    exit(0)
}
if args.contains("--resume") {
    try? FileManager.default.removeItem(atPath: pauseFile)
    print("resumed")
    exit(0)
}

// startup reconciliation: never leave the display neutralised after a crash
var state = loadState()
if state.mode == "hdr" {
    if fullscreenOwner() == nil {
        log("startup: found state=hdr with nothing fullscreen — restoring")
        let s = restore(state.saved, dryRun: dryRun)
        state = State(mode: "tuned", saved: nil, tuned: s); saveState(state)
    } else {
        log("startup: resuming in hdr state (content still fullscreen)")
    }
}

var pendingSince: Date?
var lastReassert = Date.distantPast

func evaluate() {
    if isPaused() { pendingSince = nil; return }
    guard displayIsHDR() else { pendingSince = nil; return }   // clamp irrelevant outside HDR
    let owner = fullscreenOwner()

    // re-assert the active state if BetterDisplay drifted (restart, user nudge)
    if Date().timeIntervalSince(lastReassert) >= reassertSeconds {
        if state.mode == "hdr" {
            _ = bdSet(neutral)
        } else if let saved = state.saved {
            _ = bdSet([("brightness", saved.brightness), ("gamma", saved.gamma), ("temperature", saved.temperature)])
        }
        lastReassert = Date()
    }

    switch (owner != nil, state.mode) {
    case (true, "tuned"):
        if pendingSince == nil { pendingSince = Date() }
        if let since = pendingSince, Date().timeIntervalSince(since) >= effectiveGraceEnter {
            if let saved = captureAndNeutralise(dryRun: dryRun) {
                state = State(mode: "hdr", saved: saved, tuned: saved); saveState(state)
            }
            pendingSince = nil
        }
    case (false, "hdr"):
        if pendingSince == nil { pendingSince = Date() }
        if let since = pendingSince, Date().timeIntervalSince(since) >= effectiveGraceExit {
            let s = restore(state.saved, dryRun: dryRun)
            state = State(mode: "tuned", saved: nil, tuned: s); saveState(state)
            pendingSince = nil
        }
    default:
        pendingSince = nil
    }
}

// restore on exit so a stop never leaves the display neutralised
func shutdown() {
    if state.mode == "hdr" {
        let s = restore(state.saved, dryRun: dryRun)
        saveState(State(mode: "tuned", saved: nil, tuned: s))
    }
    log("exiting cleanly")
}
signal(SIGTERM) { _ in shutdown(); exit(0) }
signal(SIGINT) { _ in shutdown(); exit(0) }

log("watcher started (poll \(pollSeconds)s, grace \(graceSeconds)s, display \(targetScreenName))")
if once {
    evaluate()
    log("single evaluation done, mode=\(state.mode)")
    exit(0)
}
var consecutiveFailures = 0
var lastFailureLog = Date.distantPast
var lastSeenOwner: Date = .distantPast

while true {
    let before = state.mode
    evaluate()
    let owner = fullscreenOwner()
    if owner != nil { lastSeenOwner = Date() }
    if state.mode != before { consecutiveFailures = 0 }

    // BetterDisplay missing or not answering: back off instead of logging 4x/second
    if bdGet("hdr") == nil {
        consecutiveFailures += 1
        if Date().timeIntervalSince(lastFailureLog) > 60 {
            log("BetterDisplay not answering (failures=\(consecutiveFailures)) — backing off")
            lastFailureLog = Date()
        }
        if consecutiveFailures > 3 {
            Thread.sleep(forTimeInterval: 5.0)
            continue
        }
    } else {
        consecutiveFailures = 0
    }

    let active = state.mode == "hdr" || Date().timeIntervalSince(lastSeenOwner) < 5
    Thread.sleep(forTimeInterval: active ? fastPollSeconds : pollSeconds)
}
