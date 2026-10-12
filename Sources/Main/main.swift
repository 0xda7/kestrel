// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

// Thin launcher: everything real lives in the KestrelCore library (the whole
// app compiles as a library so the check suite can @testable-import it from
// an executable; App.main() is public on SwiftUI's App protocol).
import KestrelCore

KestrelApp.main()
