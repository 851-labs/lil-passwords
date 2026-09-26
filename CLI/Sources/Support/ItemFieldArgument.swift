import ArgumentParser
import LilpwCore

/// Lets `--field <value>` accept any `ItemField` case by name (`password`, `username`, `totp`,
/// `notes`, `website`), case-sensitively matching its lowercase `rawValue`.
///
/// `ItemField` itself lives in `LilpwCore`, which deliberately has no `ArgumentParser` dependency
/// (see `LilpwCore`'s package documentation) — this conformance lives here, in the CLI target,
/// instead. Since `ItemField` is already `CaseIterable & RawRepresentable<String>`,
/// `ExpressibleByArgument`'s own default extension supplies `init?(argument:)`, and `--help`
/// automatically lists every case via `allValueStrings`.
extension ItemField: ExpressibleByArgument {}
