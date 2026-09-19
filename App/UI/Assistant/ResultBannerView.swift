import Agent
import SwiftUI

/// The outcome of the last action ("Message sent to Alex Kim"), shown briefly at the top.
struct ResultBannerView: View {
    let banner: ResultBanner

    var body: some View {
        let tone = banner.style.tone
        HStack(spacing: 10) {
            Image(systemName: banner.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tone == .neutral ? Palette.inkSecondary : tone.color)
                .accessibilityHidden(true)
            Text(banner.text)
                .textStyle(.subheadline, weight: .semibold)
                .foregroundStyle(Palette.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .padding(.vertical, 11)
        .glassSurface(Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(banner.text)
    }
}

#Preview("Result banners") {
    VStack(spacing: 16) {
        ResultBannerView(banner: GallerySamples.successBanner)
        ResultBannerView(banner: GallerySamples.cancelledBanner)
        ResultBannerView(banner: GallerySamples.failureBanner)
    }
    .padding()
}
