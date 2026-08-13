import SwiftUI

/// Center-calibration flow. Presented while connected to the gate: the player
/// rolls balls through the centering jig, and each complete roll trains a
/// per-sensor baseline (routed here by `GateConnection` while `isCalibrating`).
/// Saving commits the baseline as the active calibration, which is then
/// subtracted from every future putt so centered rolls read ~0.
struct CalibrationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var gate: GateConnection
    @EnvironmentObject private var calibration: CalibrationStore

    /// A calibration reads best with a handful of rolls; below this we nudge for
    /// more before saving (saving is still allowed).
    private let recommendedRolls = 5

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 14) {
                    instructions
                    if gate.state != .connected { disconnectedNote }
                    countCard
                    if !calibration.liveBaselineMm.isEmpty { baselineCard }
                    if calibration.active != nil { existingNote }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pgScreenBackground()
        .tint(.pgAccent)
        .onAppear { calibration.begin() }
        .onDisappear {
            // Leaving without saving abandons the capture; the active calibration
            // (if any) is untouched.
            if calibration.isCalibrating { calibration.cancel() }
        }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(PGGhostButtonStyle(color: .pgNeutral700, size: 15))
            Spacer()
            Text("Calibrate center")
                .font(.pgHeading(17, relativeTo: .headline))
                .foregroundStyle(Color.pgText)
            Spacer()
            // Balance the leading Cancel so the title stays centered.
            Text("Cancel").font(.pgBody(15, weight: .semibold)).opacity(0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Button("Save calibration") {
                calibration.finish(gateName: gate.connectedName)
                dismiss()
            }
            .buttonStyle(PGPrimaryButtonStyle())
            .disabled(calibration.sampleCount == 0)
            .opacity(calibration.sampleCount == 0 ? 0.5 : 1)

            Button("Reset rolls") { calibration.begin() }
                .buttonStyle(PGGhostButtonStyle(color: .pgNeutral700, size: 14))
                .disabled(calibration.sampleCount == 0)
                .opacity(calibration.sampleCount == 0 ? 0.4 : 1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    // MARK: Cards

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Roll through the jig")
                .font(.pgHeading(20, relativeTo: .title3))
                .foregroundStyle(Color.pgText)
            Text("Set the centering jig in the gate and roll a ball straight down "
                 + "the middle. Each clean roll trains the center baseline — do a "
                 + "few, then save. The baseline is subtracted from every putt so "
                 + "your readings stay consistent.")
                .font(.pgBody(13))
                .foregroundStyle(Color.pgNeutral700)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .pgCard()
    }

    private var disconnectedNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.pgAccent)
            Text("Gate not connected — rolls won't register until it reconnects.")
                .font(.pgBody(13))
                .foregroundStyle(Color.pgNeutral700)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .pgCard()
    }

    private var countCard: some View {
        VStack(spacing: 6) {
            Text("\(calibration.sampleCount)")
                .font(.pgHeading(48, relativeTo: .largeTitle))
                .foregroundStyle(Color.pgText)
                .contentTransition(.numericText())
                .animation(.snappy, value: calibration.sampleCount)
            Text(calibration.sampleCount == 1 ? "roll captured" : "rolls captured")
                .font(.pgBody(13))
                .foregroundStyle(Color.pgNeutral700)
            if calibration.sampleCount < recommendedRolls {
                Text("Aim for \(recommendedRolls)+ for a stable baseline.")
                    .font(.pgBody(12))
                    .foregroundStyle(Color.pgNeutral600)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .pgCard()
    }

    private var baselineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            PGSectionHeader("Center baseline")
            HStack {
                Text("Average")
                    .font(.pgBody(14))
                    .foregroundStyle(Color.pgNeutral700)
                Spacer()
                Text(mm(average(calibration.liveBaselineMm)))
                    .font(.pgBody(15, weight: .semibold))
                    .foregroundStyle(Color.pgText)
            }
            PGDivider()
            ForEach(Array(calibration.liveBaselineMm.enumerated()), id: \.offset) { index, value in
                HStack {
                    Text("Sensor \(index + 1)")
                        .font(.pgBody(14))
                        .foregroundStyle(Color.pgNeutral700)
                    Spacer()
                    if let roll = calibration.lastRollMm, index < roll.count {
                        Text("last \(mm(roll[index]))")
                            .font(.pgBody(12))
                            .foregroundStyle(Color.pgNeutral500)
                            .padding(.trailing, 10)
                    }
                    Text(mm(value))
                        .font(.pgBody(15, weight: .semibold))
                        .foregroundStyle(Color.pgText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .pgCard()
    }

    private var existingNote: some View {
        Text("Saving replaces your current calibration.")
            .font(.pgBody(12))
            .foregroundStyle(Color.pgNeutral600)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
    }

    // MARK: Helpers

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func mm(_ value: Double) -> String {
        String(format: "%+.1f mm", value)
    }
}
