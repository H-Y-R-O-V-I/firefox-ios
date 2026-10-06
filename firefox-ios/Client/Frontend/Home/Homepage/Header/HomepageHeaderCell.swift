// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import UIKit
import Common
import Shared
import QuickAnswersKit
import TipKit

// Header for the homepage in both normal and private mode
// Contains HYROVI Browser branding, and optionally the Quick Answers button
class HomepageHeaderCell: UICollectionViewCell, ReusableCell, ThemeApplicable, FeatureFlaggable {
    enum UX {
        static let brandLogoImageSize = CGSize(width: 40, height: 40)
        static let privateNovaLogoImageSize = CGSize(width: 72, height: 72)
        static let brandTextSize = CGSize(width: 126, height: 40)
        static let interImageSpacing: CGFloat = 10
        static let quickAnswersButtonSize: CGFloat = 44

        static func contentWidth() -> CGFloat {
            return UX.brandLogoImageSize.width + UX.interImageSpacing + UX.brandTextSize.width
        }
    }

    typealias a11y = AccessibilityIdentifiers.FirefoxHomepage.OtherButtons

    private var headerState: HeaderState?
    private var logoTextColor: UIColor?
    private var showiPadSetup = false
    private weak var tipPresenter: UIViewController?
    private weak var tipPopoverController: UIViewController?
    private var tipObservationTask: Task<Void, Never>?
    private lazy var logoContainerView: UIView = .build()

    private lazy var logoStackView: UIStackView = .build { view in
        view.backgroundColor = .clear
        view.alignment = .center
        view.spacing = UX.interImageSpacing
        view.accessibilityIdentifier = a11y.logoID
        view.accessibilityLabel = AppName.shortName.rawValue
        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
    }

    private lazy var logoImage: UIImageView = .build { imageView in
        imageView.contentMode = .scaleAspectFit
    }

    private lazy var brandTextLabel: UILabel = .build { label in
        label.text = "HYROVI Browser"
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textAlignment = .left
        label.adjustsFontForContentSizeCategory = true
        label.minimumScaleFactor = 0.78
        label.adjustsFontSizeToFitWidth = true
    }

    private lazy var quickAnswersButton: UIButton = .build { [weak self] button in
        button.configuration = .filled()
        button.configuration?.image = UIImage(named: StandardImageIdentifiers.Large.audioWave)?
            .withRenderingMode(.alwaysTemplate)
        button.configuration?.cornerStyle = .capsule
        button.accessibilityLabel = .QuickAnswers.AccessibilityLabels.OpenQuickAnswers
        button.accessibilityIdentifier = a11y.quickAnswersButton
        button.adjustsImageSizeForAccessibilityContentSizeCategory = false
        button.addAction(UIAction(handler: { _ in
            self?.quickAnswerButtonTapped()
        }), for: .touchUpInside)
    }
    private lazy var logoCenterConstraint = logoContainerView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
    private lazy var logoLeadingConstraint = logoContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
    private lazy var logoImageWidthConstraint = logoImage.widthAnchor.constraint(
        equalToConstant: UX.brandLogoImageSize.width
    )
    private lazy var logoImageHeightConstraint = logoImage.heightAnchor.constraint(
        equalToConstant: UX.brandLogoImageSize.height
    )

    // MARK: - Initializers
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Setup

    private func setupLayout() {
        contentView.backgroundColor = .clear

        logoStackView.addArrangedSubview(logoImage)
        logoStackView.addArrangedSubview(brandTextLabel)
        logoContainerView.addSubview(logoStackView)

        contentView.addSubview(logoContainerView)
        contentView.addSubview(quickAnswersButton)

        logoStackView.pinToSuperview()

        setupConstraints()
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            logoImageWidthConstraint,
            logoImageHeightConstraint,
            brandTextLabel.widthAnchor.constraint(equalToConstant: UX.brandTextSize.width),
            brandTextLabel.heightAnchor.constraint(equalToConstant: UX.brandTextSize.height),

            logoContainerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            logoContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            logoContainerView.trailingAnchor.constraint(lessThanOrEqualTo: quickAnswersButton.leadingAnchor),

            quickAnswersButton.widthAnchor.constraint(equalToConstant: UX.quickAnswersButtonSize),
            quickAnswersButton.heightAnchor.constraint(equalToConstant: UX.quickAnswersButtonSize),
            quickAnswersButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            quickAnswersButton.centerYAnchor.constraint(equalTo: logoContainerView.centerYAnchor),
            quickAnswersButton.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor),
            quickAnswersButton.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor)
        ])
    }

    func configure(headerState: HeaderState,
                   showiPadSetup: Bool = false,
                   logoTextColor: UIColor? = nil,
                   tipPresenter: UIViewController? = nil) {
        self.headerState = headerState
        self.showiPadSetup = showiPadSetup
        self.logoTextColor = logoTextColor
        self.tipPresenter = tipPresenter

        let isNovaPrivate = featureFlagsProvider.isEnabled(.novaDesign) && headerState.isPrivate

        let logoSize = isNovaPrivate ? UX.privateNovaLogoImageSize : UX.brandLogoImageSize
        logoImageWidthConstraint.constant = logoSize.width
        logoImageHeightConstraint.constant = logoSize.height
        brandTextLabel.isHidden = isNovaPrivate

        logoImage.image = isNovaPrivate
            ? UIImage(named: StandardImageIdentifiers.ExtraExtraExtraLarge.privateModeCircleFillMulticolor)
            : UIImage(named: "hyroviBrandLogo")

        quickAnswersButton.isHidden = !headerState.showQuickAnswersButton

        // if the quick answers button is visible and we are on iPhone setup, align the logo to the leading
        let alignLogoToLeading = headerState.showQuickAnswersButton && !showiPadSetup
        logoCenterConstraint.isActive = !alignLogoToLeading
        logoLeadingConstraint.isActive = alignLogoToLeading

        if headerState.showQuickAnswersButton {
            observeQuickAnswersTip()
        } else {
            cancelQuickAnswersTipObservation()
        }
    }

    private func observeQuickAnswersTip() {
        guard #available(iOS 17.0, *),
              tipObservationTask == nil else { return }

        tipObservationTask = Task { @MainActor [weak self] in
            let tip = QuickAnswersTip()

            for await status in tip.statusUpdates {
                guard !Task.isCancelled else { return }

                switch status {
                // Wait for TipKit to finish evaluating the tip's display eligibility.
                case .pending:
                    continue

                case .available:
                    guard let tipPresenter = self?.tipPresenter,
                          tipPresenter.presentedViewController == nil,
                          let sourceItem = self?.quickAnswersButton
                    else { return }

                    let popover = TipUIPopoverViewController(tip, sourceItem: sourceItem)
                    popover.popoverPresentationController?.permittedArrowDirections = .up
                    self?.tipPopoverController = popover
                    tipPresenter.present(popover, animated: true)

                // Dismiss the presented tip when TipKit marks it as closed or otherwise invalid.
                case .invalidated:
                    guard let tipPresenter = self?.tipPresenter,
                          let popover = self?.tipPopoverController,
                          tipPresenter.presentedViewController === popover
                    else { return }

                    tipPresenter.dismiss(animated: true)
                    self?.tipPopoverController = nil
                    return

                @unknown default:
                    break
                }
            }
        }
    }

    private func cancelQuickAnswersTipObservation() {
        tipObservationTask?.cancel()
        tipObservationTask = nil
    }

    private func quickAnswerButtonTapped() {
        guard let headerState else { return }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        let transitionType: QuickAnswersTransitionType = if showiPadSetup {
            .formSheet
        } else {
            // convert the button frame to the parent window frame to have correct transition.
            .crossDissolve(sourceRect: quickAnswersButton.convert(quickAnswersButton.bounds, to: nil))
        }
        store.dispatch(
            NavigationBrowserAction(
                navigationDestination: NavigationDestination(.quickAnswers(transitionType: transitionType)),
                windowUUID: headerState.windowUUID,
                actionType: NavigationBrowserActionType.tapOnQuickAnswersButton
            )
        )
    }

    // MARK: - ThemeApplicable
    func applyTheme(theme: Theme) {
        brandTextLabel.textColor = logoTextColor ?? theme.colors.textPrimary

        quickAnswersButton.configuration?.baseBackgroundColor = theme.colors.layer4
        quickAnswersButton.configuration?.baseForegroundColor = theme.colors.actionPrimary
    }
}
