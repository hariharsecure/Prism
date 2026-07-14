import Foundation

// prism-bench [runs] [secondsPerRun] — 4K60 multi-source judged stress benchmark
let a = CommandLine.arguments.dropFirst()
let runs = a.first.flatMap(Int.init) ?? 20
let secs = a.dropFirst().first.flatMap(Double.init) ?? 5.0
try await cmdBench(runs: max(1, runs), seconds: max(1, secs))
