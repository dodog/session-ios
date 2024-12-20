//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import UIKit
import SessionUIKit
import SessionUtilitiesKit

public enum PhotoGridItemType {
    case photo, animated, video
}

public protocol PhotoGridItem: AnyObject {
    var type: PhotoGridItemType { get }
    
    func asyncThumbnail(completion: @escaping (UIImage?) -> Void)
}

public class PhotoGridViewCell: UICollectionViewCell {
    public let imageView: UIImageView

    private let contentTypeBadgeView: UIImageView
    private let selectedBadgeView: UIImageView

    private let highlightedView: UIView
    private let selectedView: UIView

    var item: PhotoGridItem?

    private static let videoBadgeImage = #imageLiteral(resourceName: "ic_gallery_badge_video")
    private static let animatedBadgeImage = #imageLiteral(resourceName: "ic_gallery_badge_gif")
    private static let selectedBadgeImage = UIImage(systemName: "checkmark.circle.fill")

    public var loadingColor: ThemeValue = .textSecondary

    override public var isSelected: Bool {
        didSet {
            self.selectedBadgeView.isHidden = !self.isSelected
            self.selectedView.isHidden = !self.isSelected
        }
    }

    override public var isHighlighted: Bool {
        didSet {
            self.highlightedView.isHidden = !self.isHighlighted
        }
    }

    override init(frame: CGRect) {
        self.imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill

        self.contentTypeBadgeView = UIImageView()
        contentTypeBadgeView.isHidden = true

        let kSelectedBadgeSize = CGSize(width: 32, height: 32)
        self.selectedBadgeView = UIImageView()
        selectedBadgeView.image = PhotoGridViewCell.selectedBadgeImage?.withRenderingMode(.alwaysTemplate)
        selectedBadgeView.themeTintColor = .primary
        selectedBadgeView.themeBorderColor = .textPrimary
        selectedBadgeView.themeBackgroundColor = .textPrimary
        selectedBadgeView.isHidden = true
        selectedBadgeView.layer.cornerRadius = (kSelectedBadgeSize.width / 2)

        self.highlightedView = UIView()
        highlightedView.alpha = 0.2
        highlightedView.themeBackgroundColor = .black
        highlightedView.isHidden = true

        self.selectedView = UIView()
        selectedView.alpha = 0.3
        selectedView.themeBackgroundColor = .black
        selectedView.isHidden = true

        super.init(frame: frame)

        self.clipsToBounds = true

        self.contentView.addSubview(imageView)
        self.contentView.addSubview(contentTypeBadgeView)
        self.contentView.addSubview(highlightedView)
        self.contentView.addSubview(selectedView)
        self.contentView.addSubview(selectedBadgeView)

        imageView.pin(to: contentView)
        highlightedView.pin(to: contentView)
        selectedView.pin(to: contentView)

        // Note assets were rendered to match exactly. We don't want to re-size with
        // content mode lest they become less legible.
        contentTypeBadgeView.pin(.leading, to: .leading, of: contentView, withInset: 3)
        contentTypeBadgeView.pin(.bottom, to: .bottom, of: contentView, withInset: -3)
        contentTypeBadgeView.set(.width, to: 18)
        contentTypeBadgeView.set(.height, to: 12)

        selectedBadgeView.pin(.trailing, to: .trailing, of: contentView, withInset: -Values.verySmallSpacing)
        selectedBadgeView.pin(.bottom, to: .bottom, of: contentView, withInset: -Values.verySmallSpacing)
        selectedBadgeView.set(.width, to: kSelectedBadgeSize.width)
        selectedBadgeView.set(.height, to: kSelectedBadgeSize.height)
    }

    @available(*, unavailable, message: "Unimplemented")
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var image: UIImage? {
        get { return imageView.image }
        set {
            imageView.image = newValue
            imageView.themeBackgroundColor = (newValue == nil ? loadingColor : .clear)
        }
    }

    var contentTypeBadgeImage: UIImage? {
        get { return contentTypeBadgeView.image }
        set {
            contentTypeBadgeView.image = newValue
            contentTypeBadgeView.isHidden = newValue == nil
        }
    }

    public func configure(item: PhotoGridItem) {
        self.item = item

        item.asyncThumbnail { [weak self] image in
            guard let currentItem = self?.item else { return }
            guard currentItem === item else { return }

            if image == nil {
                Log.debug("[PhotoGridViewCell] image == nil")
            }
            
            DispatchQueue.main.async {
                self?.image = image
            }
        }

        switch item.type {
            case .video: self.contentTypeBadgeImage = PhotoGridViewCell.videoBadgeImage
            case .animated: self.contentTypeBadgeImage = PhotoGridViewCell.animatedBadgeImage
            case .photo: self.contentTypeBadgeImage = nil
        }
    }

    override public func prepareForReuse() {
        super.prepareForReuse()

        self.item = nil
        self.imageView.image = nil
        self.contentTypeBadgeView.isHidden = true
        self.highlightedView.isHidden = true
        self.selectedView.isHidden = true
        self.selectedBadgeView.isHidden = true
    }
}
