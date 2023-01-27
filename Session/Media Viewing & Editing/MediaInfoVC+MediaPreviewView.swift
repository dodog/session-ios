// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

extension MediaInfoVC {
    final class MediaPreviewView: UIView {
        private static let cornerRadius: CGFloat = 8
        
        private let attachment: Attachment
        private let isOutgoing: Bool
        
        // MARK: - UI
        
        private lazy var mediaView: MediaView = {
            let result: MediaView = MediaView.init(
                attachment: attachment,
                isOutgoing: isOutgoing
            )
            
            return result
        }()
        
        private lazy var fullScreenButton: UIButton = {
            let result: UIButton = UIButton(type: .custom)
            result.setImage(
                UIImage(systemName: "arrow.up.left.and.arrow.down.right")?
                    .withRenderingMode(.alwaysTemplate),
                for: .normal
            )
            result.themeTintColor = .textPrimary
            result.backgroundColor = .init(white: 0, alpha: 0.4)
            result.layer.cornerRadius = 14
            result.set(.width, to: 28)
            result.set(.height, to: 28)
            result.addTarget(self, action: #selector(showMediaFullScreen), for: .touchUpInside)
            
            return result
        }()
        
        // MARK: - Lifecycle
        
        init(attachment: Attachment, isOutgoing: Bool) {
            self.attachment = attachment
            self.isOutgoing = isOutgoing
            
            super.init(frame: CGRect.zero)
            self.accessibilityLabel = "Media info"
            setUpViewHierarchy()
        }

        override init(frame: CGRect) {
            preconditionFailure("Use init(attachment:) instead.")
        }

        required init?(coder: NSCoder) {
            guard let attachment = coder.decodeObject(forKey: "attachment") as? Attachment else {
                print("No attachment")
                return nil
            }
            guard let isOutgoing = coder.decodeObject(forKey: "isOutgoing") as? Bool else {
                print("No isOutgoing")
                return nil
            }
            
            self.attachment = attachment
            self.isOutgoing = isOutgoing
            
            super.init(coder: coder)
            self.accessibilityLabel = "Media info"
            setUpViewHierarchy()
        }
        
        override func encode(with coder: NSCoder) {
            super.encode(with: coder)
//            coder.encode(self.attachment, forKey: "attachment")
            coder.encode(self.isOutgoing, forKey: "isOutgoing")
            
        }

        private func setUpViewHierarchy() {
            set(.width, to: MediaInfoVC.mediaSize)
            set(.height, to: MediaInfoVC.mediaSize)
            
            addSubview(mediaView)
            mediaView.pin(to: self)
            
            addSubview(fullScreenButton)
            fullScreenButton.pin(.trailing, to: .trailing, of: self, withInset: -Values.smallSpacing)
            fullScreenButton.pin(.bottom, to: .bottom, of: self, withInset: -Values.smallSpacing)
            
            mediaView.loadMedia()
        }
        
        // MARK: - Interaction
        @objc func showMediaFullScreen() {
            
        }
    }
}
