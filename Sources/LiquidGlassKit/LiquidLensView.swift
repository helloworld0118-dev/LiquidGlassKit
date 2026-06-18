//
//  LiquidLensView.swift
//  LiquidGlass
//
//  Created by Alexey Demin on 2025-12-19.
//

import UIKit
internal import MetalKit

/// A custom implementation of the private _UILiquidLensView used in UITabBar.
/// Provides a resting state with a semi-transparent white pill that morphs
/// into a LiquidGlassView when lifted.
public final class LiquidLensView: UIView, AnyLiquidLensView {
    public enum Preset {
        case standard
        case tabBar
    }

    // MARK: - Acceleration Constants
    
    /// Time window for calculating average acceleration (in seconds).
    private let accelerationWindowDuration: TimeInterval = 0.3

    /// Coefficient to convert acceleration to scale transform.
    private let accelerationScaleCoefficient: CGFloat = 0.00000 // Disabled to prevent unintended shrinking
    
    /// Maximum scale deviation from 1.0 (clamped for visual stability).
    private let maxScaleDeviation: CGFloat = 0.3
    
    // MARK: - Position Tracking
    
    private var positionHistory: [(position: CGPoint, timestamp: TimeInterval)] = []
    private var displayLink: CADisplayLink?
    
    // MARK: - Private Stored Views (weak references)
    
    private weak var liftedContainerView: UIView?
    private weak var liftedContentView: UIView?
    private weak var overridePunchoutView: UIView?
    
    // MARK: - Private Properties
    
    /// Whether the view is currently in lifted state.
    private var isLifted = false
    
    /// The liquid glass content mode.
    private var liftedContentMode: Int = 0
    
    /// The liquid glass style.
    private var style: Int = 0
    
    /// Whether the view warps content below it.
    private var warpsContentBelow: Bool = false

    /// The visual preset used by this lens instance.
    private let preset: Preset
    
    // MARK: - Private Views
    
    /// The resting background view - semi-transparent white pill shown in resting state.
    private let restingPillView = UIView()
    
    /// The liquid glass view shown when lifted.
    private let liquidGlassView: LiquidGlassView

    /// Extra UIKit-drawn lens chrome for tab bars. The shader supplies refraction;
    /// this supplies the thin highlights and prismatic rim that make it read as glass.
    private let tabBarChromeView: TabBarLensChromeView?
    
    // MARK: - Protocol Properties
    
    public var restingBackgroundColor: UIColor? {
        get { restingPillView.backgroundColor }
        set { restingPillView.backgroundColor = newValue }
    }
    
    // MARK: - Initialization
    
    convenience public init() {
        self.init(restingBackground: nil, preset: .standard)
    }

    convenience public init(preset: Preset) {
        self.init(restingBackground: nil, preset: preset)
    }
    
    public convenience init(restingBackground backgroundView: UIView?) {
        self.init(restingBackground: backgroundView, preset: .standard)
    }

    public init(restingBackground backgroundView: UIView?, preset: Preset) {
        self.preset = preset
        switch preset {
        case .standard:
            liquidGlassView = LiquidGlassView(.lens)
            tabBarChromeView = nil
        case .tabBar:
            liquidGlassView = LiquidGlassView(.tabBarLens)
            tabBarChromeView = TabBarLensChromeView()
        }
        super.init(frame: .zero)
        commonInit()
        if let backgroundView {
            restingPillView.addSubview(backgroundView)
        }
    }
    
    required init?(coder: NSCoder) {
        preset = .standard
        liquidGlassView = LiquidGlassView(.lens)
        tabBarChromeView = nil
        super.init(coder: coder)
        commonInit()
    }
    
    private func commonInit() {
        clipsToBounds = false
        
        // Setup resting pill view - semi-transparent white
        restingPillView.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        restingPillView.isUserInteractionEnabled = false
        addSubview(restingPillView)
        
        // Setup liquid glass view - initially hidden
        liquidGlassView.alpha = 0
        liquidGlassView.isUserInteractionEnabled = false
        // Not added to view hierarchy initially - only shown when lifted

        tabBarChromeView?.alpha = 0
    }
    
    // MARK: - Layout
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        
        // Update resting pill to fill bounds with pill shape
        restingPillView.frame = bounds
        restingPillView.layer.cornerRadius = min(bounds.width, bounds.height) / 2
        
        // Update liquid glass view to same bounds
//        liquidGlassView.frame = bounds
//        liquidGlassView.layer.cornerRadius = min(bounds.width, bounds.height) / 2
        tabBarChromeView?.frame = liquidGlassView.superview == nil ? bounds : liquidGlassView.frame
    }
    
    // MARK: - Protocol Methods
    
    public func setLiftedContainerView(_ containerView: UIView?) {
        liftedContainerView = containerView
    }
    
    public func setLiftedContentView(_ contentView: UIView?) {
        liftedContentView = contentView
    }
    
    public func setOverridePunchoutView(_ punchoutView: UIView?) {
        overridePunchoutView = punchoutView
    }
    
    public func setLifted(_ lifted: Bool, animated: Bool, alongsideAnimations: (() -> Void)?, completion: ((Bool) -> Void)?) {
        guard isLifted != lifted else {
            completion?(true)
            return
        }
        
        isLifted = lifted
        
        if lifted {
            liftUp(animated: animated, alongsideAnimations: alongsideAnimations, completion: completion)
        } else {
            liftDown(animated: animated, alongsideAnimations: alongsideAnimations, completion: completion)
        }
    }
    
    public func setLiftedContentMode(_ contentMode: Int) {
        self.liftedContentMode = contentMode
    }
    
    public func setStyle(_ style: Int) {
        self.style = style
    }
    
    public func setWarpsContentBelow(_ warpsContentBelow: Bool) {
        self.warpsContentBelow = warpsContentBelow
    }
    
    // MARK: - Private Lift Animation
    
    /// Morphs from resting pill to liquid glass view.
    private func liftUp(animated: Bool, alongsideAnimations: (() -> Void)?, completion: ((Bool) -> Void)?) {
        // Prepare liquid glass view at same position
        liquidGlassView.frame = bounds
        liquidGlassView.layer.cornerRadius = restingPillView.layer.cornerRadius
        liquidGlassView.alpha = 0
        liquidGlassView.removeFromSuperview()
        addSubview(liquidGlassView)

        if let tabBarChromeView {
            tabBarChromeView.frame = bounds
            tabBarChromeView.alpha = 0
            tabBarChromeView.removeFromSuperview()
            addSubview(tabBarChromeView)
        }
        
        // Start position tracking for acceleration-based squash/stretch
        startPositionTracking()
        
        let animations = {
            // Fade out resting pill
            self.restingPillView.alpha = 0

            // Fade in liquid glass
            self.liquidGlassView.alpha = 1

            self.tabBarChromeView?.alpha = 1
            
            alongsideAnimations?()
        }
        
        let animationCompletion: (Bool) -> Void = { finished in
            // Clean up resting pill state
            completion?(finished)
        }
        
        if animated {
            UIView.animate(
                withDuration: 0.4,
                delay: 0,
                usingSpringWithDamping: 0.7,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: animations,
                completion: animationCompletion
            )
        } else {
            animations()
            animationCompletion(true)
        }
    }
    
    /// Morphs from liquid glass view back to resting pill.
    private func liftDown(animated: Bool, alongsideAnimations: (() -> Void)?, completion: ((Bool) -> Void)?) {
        // Stop position tracking
        stopPositionTracking()
        
        // Prepare resting pill for fade in
        restingPillView.alpha = 0
        
        let animations = {
            // Fade in resting pill
            self.restingPillView.alpha = 1
            
            // Fade out liquid glass
            self.liquidGlassView.alpha = 0

            self.tabBarChromeView?.alpha = 0
            
            alongsideAnimations?()
        }
        
        let animationCompletion: (Bool) -> Void = { finished in
            guard finished else {
                completion?(finished)
                return
            }
            // Clean up liquid glass view
            self.liquidGlassView.removeFromSuperview()
            self.liquidGlassView.alpha = 1
            self.tabBarChromeView?.removeFromSuperview()
            completion?(finished)
        }
        
        if animated {
            UIView.animate(
                withDuration: 0.5,
                delay: 0,
                usingSpringWithDamping: 0.8,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: animations,
                completion: animationCompletion
            )
        } else {
            animations()
            animationCompletion(true)
        }
    }
    
    // MARK: - Position Tracking & Acceleration
    
    private func startPositionTracking() {
        positionHistory.removeAll()
        displayLink = CADisplayLink(target: self, selector: #selector(updatePositionTracking))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    private func stopPositionTracking() {
        displayLink?.invalidate()
        displayLink = nil
        positionHistory.removeAll()
        // Reset liquidGlassView to original bounds
        liquidGlassView.frame = bounds
        tabBarChromeView?.frame = bounds
    }
    
    @objc private func updatePositionTracking() {
        let currentTime = CACurrentMediaTime()
        let currentPosition = layer.position
        
        // Add current position to history
        positionHistory.append((position: currentPosition, timestamp: currentTime))
        
        // Remove old entries outside the time window
        let cutoffTime = currentTime - accelerationWindowDuration
        positionHistory.removeAll { $0.timestamp < cutoffTime }
        
        // Calculate average acceleration and apply size change
        let acceleration = calculateAverageAcceleration()
//        print(acceleration)
        applyAccelerationSize(acceleration)
    }
    
    /// Calculates the average acceleration over the position history.
    /// Returns a combined value where positive = accelerating right/up, negative = accelerating left/down.
    private func calculateAverageAcceleration() -> CGFloat {
        guard positionHistory.count >= 3 else { return 0 }
        
        // Calculate velocities between consecutive position samples
        var velocities: [(velocity: CGPoint, timestamp: TimeInterval)] = []
        for i in 1..<positionHistory.count {
            let prev = positionHistory[i - 1]
            let curr = positionHistory[i]
            let dt = curr.timestamp - prev.timestamp
            guard dt > 0 else { continue }
            
            let velocity = CGPoint(
                x: (curr.position.x - prev.position.x) / dt,
                y: (curr.position.y - prev.position.y) / dt
            )
            let midTime = (prev.timestamp + curr.timestamp) / 2
            velocities.append((velocity: velocity, timestamp: midTime))
        }
        
        guard velocities.count >= 2 else { return 0 }
        
        // Calculate accelerations between consecutive velocity samples
        var totalAccelerationX: CGFloat = 0
        var totalAccelerationY: CGFloat = 0
        var count: CGFloat = 0
        
        for i in 1..<velocities.count {
            let prev = velocities[i - 1]
            let curr = velocities[i]
            let dt = curr.timestamp - prev.timestamp
            guard dt > 0 else { continue }
            
            totalAccelerationX += (curr.velocity.x - prev.velocity.x) / dt
            totalAccelerationY += (curr.velocity.y - prev.velocity.y) / dt
            count += 1
        }
        
        guard count > 0 else { return 0 }
        
        let avgAccelerationX = totalAccelerationX / count
        let avgAccelerationY = totalAccelerationY / count
        
        // Combine accelerations:
        // - Positive X acceleration (right) or negative Y acceleration (up in UIKit coords) → stretch X
        // - Negative X acceleration (left) or positive Y acceleration (down) → squash X
        // In UIKit, Y increases downward, so upward movement = negative Y velocity,
        // and accelerating upward = negative Y acceleration.
        // We want upward acceleration to have the same effect as rightward acceleration,
        // so we subtract Y acceleration from X acceleration.
        return avgAccelerationX - avgAccelerationY
    }
    
    /// Applies squash/stretch size change to liquidGlassView based on acceleration.
    private func applyAccelerationSize(_ acceleration: CGFloat) {
        let scaleFactor = acceleration * accelerationScaleCoefficient
        
        // Clamp to reasonable range for visual stability
        let clampedScale = max(-maxScaleDeviation, min(maxScaleDeviation, scaleFactor))
        
        // Apply opposite scale to width and height to create squash/stretch effect
        // Positive acceleration → stretch width, squash height
        // Negative acceleration → squash width, stretch height
        let scaleX = 1 + clampedScale
        let scaleY = 1 - clampedScale
        
        let newWidth = bounds.width * scaleX
        let newHeight = bounds.height * scaleY
        
        // Center the new frame within bounds
        liquidGlassView.frame = CGRect(
            x: (bounds.width - newWidth) / 2,
            y: (bounds.height - newHeight) / 2,
            width: newWidth,
            height: newHeight
        )
        tabBarChromeView?.frame = liquidGlassView.frame
    }
}

private final class TabBarLensChromeView: UIView {
    private let fillLayer = CAGradientLayer()
    private let rimLayer = CAGradientLayer()
    private let rimMaskLayer = CAShapeLayer()
    private let softRimLayer = CAGradientLayer()
    private let softRimMaskLayer = CAShapeLayer()
    private let topGlintLayer = CAGradientLayer()
    private let bottomGlintLayer = CAGradientLayer()
    private let rightBloomLayer = CAGradientLayer()
    private let rightBloomMaskLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = false
        layer.masksToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.10
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 7)

        fillLayer.colors = [
            UIColor.white.withAlphaComponent(0.20).cgColor,
            UIColor.white.withAlphaComponent(0.06).cgColor,
            UIColor.white.withAlphaComponent(0.15).cgColor
        ]
        fillLayer.locations = [0, 0.48, 1]
        fillLayer.startPoint = CGPoint(x: 0.18, y: 0)
        fillLayer.endPoint = CGPoint(x: 0.85, y: 1)
        layer.addSublayer(fillLayer)

        softRimLayer.colors = [
            UIColor.white.withAlphaComponent(0.35).cgColor,
            UIColor(red: 1.0, green: 0.90, blue: 0.66, alpha: 0.22).cgColor,
            UIColor(red: 0.57, green: 0.90, blue: 1.0, alpha: 0.38).cgColor,
            UIColor.white.withAlphaComponent(0.24).cgColor
        ]
        softRimLayer.locations = [0, 0.36, 0.74, 1]
        softRimLayer.startPoint = CGPoint(x: 0, y: 0)
        softRimLayer.endPoint = CGPoint(x: 1, y: 1)
        softRimLayer.mask = softRimMaskLayer
        layer.addSublayer(softRimLayer)

        rimLayer.colors = [
            UIColor.white.withAlphaComponent(0.92).cgColor,
            UIColor.white.withAlphaComponent(0.34).cgColor,
            UIColor(red: 1.0, green: 0.88, blue: 0.55, alpha: 0.50).cgColor,
            UIColor(red: 0.48, green: 0.87, blue: 1.0, alpha: 0.58).cgColor,
            UIColor.white.withAlphaComponent(0.84).cgColor
        ]
        rimLayer.locations = [0, 0.28, 0.52, 0.78, 1]
        rimLayer.startPoint = CGPoint(x: 0.06, y: 0)
        rimLayer.endPoint = CGPoint(x: 1, y: 1)
        rimLayer.mask = rimMaskLayer
        layer.addSublayer(rimLayer)

        topGlintLayer.colors = [
            UIColor.white.withAlphaComponent(0).cgColor,
            UIColor.white.withAlphaComponent(0.70).cgColor,
            UIColor.white.withAlphaComponent(0.18).cgColor,
            UIColor.white.withAlphaComponent(0).cgColor
        ]
        topGlintLayer.locations = [0, 0.22, 0.78, 1]
        topGlintLayer.startPoint = CGPoint(x: 0, y: 0.5)
        topGlintLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(topGlintLayer)

        bottomGlintLayer.colors = [
            UIColor(red: 0.40, green: 0.82, blue: 1.0, alpha: 0).cgColor,
            UIColor(red: 0.40, green: 0.82, blue: 1.0, alpha: 0.34).cgColor,
            UIColor.white.withAlphaComponent(0.60).cgColor,
            UIColor(red: 0.40, green: 0.82, blue: 1.0, alpha: 0.28).cgColor,
            UIColor(red: 0.40, green: 0.82, blue: 1.0, alpha: 0).cgColor
        ]
        bottomGlintLayer.locations = [0, 0.18, 0.52, 0.82, 1]
        bottomGlintLayer.startPoint = CGPoint(x: 0, y: 0.5)
        bottomGlintLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(bottomGlintLayer)

        rightBloomLayer.colors = [
            UIColor.white.withAlphaComponent(0).cgColor,
            UIColor(red: 0.95, green: 0.76, blue: 1.0, alpha: 0.18).cgColor,
            UIColor(red: 0.44, green: 0.88, blue: 1.0, alpha: 0.24).cgColor,
            UIColor.white.withAlphaComponent(0).cgColor
        ]
        rightBloomLayer.locations = [0, 0.42, 0.78, 1]
        rightBloomLayer.startPoint = CGPoint(x: 0, y: 0)
        rightBloomLayer.endPoint = CGPoint(x: 1, y: 1)
        rightBloomLayer.mask = rightBloomMaskLayer
        layer.addSublayer(rightBloomLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let cornerRadius = bounds.height / 2
        let fillFrame = bounds.insetBy(dx: 1.0, dy: 1.0)
        fillLayer.frame = bounds
        fillLayer.cornerRadius = cornerRadius

        let rimFrame = bounds.insetBy(dx: 1.0, dy: 1.0)
        let rimPath = UIBezierPath(
            roundedRect: rimFrame,
            cornerRadius: max(0, cornerRadius - 1.0)
        ).cgPath
        rimLayer.frame = bounds
        rimMaskLayer.path = rimPath
        rimMaskLayer.fillColor = UIColor.clear.cgColor
        rimMaskLayer.strokeColor = UIColor.black.cgColor
        rimMaskLayer.lineWidth = 1.6

        softRimLayer.frame = bounds
        softRimMaskLayer.path = UIBezierPath(
            roundedRect: fillFrame,
            cornerRadius: max(0, cornerRadius - 1.0)
        ).cgPath
        softRimMaskLayer.fillColor = UIColor.clear.cgColor
        softRimMaskLayer.strokeColor = UIColor.black.cgColor
        softRimMaskLayer.lineWidth = 5.5

        topGlintLayer.frame = CGRect(
            x: 18,
            y: 5.5,
            width: max(0, bounds.width - 36),
            height: 2.4
        )
        topGlintLayer.cornerRadius = topGlintLayer.bounds.height / 2

        bottomGlintLayer.frame = CGRect(
            x: 30,
            y: bounds.height - 7.5,
            width: max(0, bounds.width - 60),
            height: 2.8
        )
        bottomGlintLayer.cornerRadius = bottomGlintLayer.bounds.height / 2

        rightBloomLayer.frame = bounds
        let rightBloomPath = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 2.5, dy: 2.5),
            cornerRadius: max(0, cornerRadius - 2.5)
        ).cgPath
        rightBloomMaskLayer.path = rightBloomPath
        rightBloomMaskLayer.fillColor = UIColor.clear.cgColor
        rightBloomMaskLayer.strokeColor = UIColor.black.cgColor
        rightBloomMaskLayer.lineWidth = 4

        layer.shadowPath = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 4, dy: 3),
            cornerRadius: max(0, cornerRadius - 3)
        ).cgPath
    }
}

@MainActor @objc public protocol AnyLiquidLensView {
    init()
    init(restingBackground backgroundView: UIView?)
    var restingBackgroundColor: UIColor? { get set }
    func setLiftedContainerView(_ containerView: UIView?)
    func setLiftedContentView(_ contentView: UIView?)
    func setOverridePunchoutView(_ punchoutView: UIView?)
    func setLifted(_ lifted: Bool, animated: Bool, alongsideAnimations: (() -> Void)?, completion: ((Bool) -> Void)?)
    func setLiftedContentMode(_ contentMode: Int)
    func setStyle(_ style: Int)
    func setWarpsContentBelow(_ warpsContentBelow: Bool)
}

public typealias UILiquidLensView = UIView & AnyLiquidLensView
