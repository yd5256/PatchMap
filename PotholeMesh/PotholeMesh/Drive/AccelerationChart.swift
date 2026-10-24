//
//  AccelerationChart.swift
//  PotholeMesh
//
//  Swift Charts line of recent acceleration magnitude at ~10 Hz, drawn only from the
//  2 s in-memory motion buffer (Requirement 14.3).
//

import Charts
import SwiftUI

struct AccelerationChart: View {
    let points: [AccelerationPoint]
    var windowSeconds: Double = DetectionConfig.standard.windowSeconds
    var minPeakG: Double = DetectionConfig.standard.minPeakG

    var body: some View {
        Chart {
            RuleMark(y: .value("Impact threshold", minPeakG))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            ForEach(points) { point in
                LineMark(
                    x: .value("Seconds", point.offsetSeconds),
                    y: .value("Acceleration (g)", point.magnitudeG)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(DefectState.confirmed.color)
            }
        }
        .chartXScale(domain: -windowSeconds...0)
        .chartYScale(domain: 0...max(1.0, (points.map(\.magnitudeG).max() ?? 0) * 1.1))
        .chartXAxis {
            AxisMarks(values: .stride(by: 0.5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(seconds == 0 ? "now" : "\(seconds, format: .number.precision(.fractionLength(1)))s")
                    }
                }
            }
        }
        .chartYAxisLabel("g")
        .frame(height: 140)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recent acceleration")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let peak = points.map(\.magnitudeG).max() else { return "No data" }
        return "Peak \(peak.formatted(.number.precision(.fractionLength(2)))) g over the last \(Int(windowSeconds)) seconds"
    }
}

#Preview {
    AccelerationChart(points: (0..<20).map {
        AccelerationPoint(offsetSeconds: Double($0 - 19) / 10, magnitudeG: $0 == 14 ? 1.4 : 0.05 + Double($0 % 3) * 0.02)
    })
    .padding()
}
