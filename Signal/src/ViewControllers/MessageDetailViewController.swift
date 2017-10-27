//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc
enum MessageMetadataViewMode: UInt {
    case focusOnMessage
    case focusOnMetadata
}

class MessageDetailViewController: OWSViewController, UIScrollViewDelegate {

    static let TAG = "[MessageDetailViewController]"
    let TAG = "[MessageDetailViewController]"

    // MARK: Properties

    let contactsManager: OWSContactsManager

    let databaseConnection: YapDatabaseConnection

    let bubbleFactory = OWSMessagesBubbleImageFactory()
    var bubbleView: UIView?

    let mode: MessageMetadataViewMode
    let viewItem: ConversationViewItem
    var message: TSMessage

    var mediaMessageView: MediaMessageView?

    // See comments on updateTextLayout.
    var messageTextView: UITextView?
    var messageTextProxyView: UIView?
    var messageTextTopConstraint: NSLayoutConstraint?
    var messageTextHeightLayoutConstraint: NSLayoutConstraint?
    var messageTextProxyViewHeightConstraint: NSLayoutConstraint?

    var scrollView: UIScrollView?
    var contentView: UIView?

    var attachment: TSAttachment?
    var dataSource: DataSource?
    var attachmentStream: TSAttachmentStream?
    var messageBody: String?

    // MARK: Initializers

    @available(*, unavailable, message:"use other constructor instead.")
    required init?(coder aDecoder: NSCoder) {
        fatalError("\(#function) is unimplemented.")
    }

    required init(viewItem: ConversationViewItem, message: TSMessage, mode: MessageMetadataViewMode) {
        self.contactsManager = Environment.getCurrent().contactsManager
        self.viewItem = viewItem
        self.message = message
        self.mode = mode
        self.databaseConnection = TSStorageManager.shared().newDatabaseConnection()!
        super.init(nibName: nil, bundle: nil)
    }

    // MARK: View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        self.databaseConnection.beginLongLivedReadTransaction()
        updateDBConnectionAndMessageToLatest()

        self.navigationItem.title = NSLocalizedString("MESSAGE_METADATA_VIEW_TITLE",
                                                      comment: "Title for the 'message metadata' view.")

        createViews()

        self.view.layoutIfNeeded()

        if mode == .focusOnMetadata {
            if let bubbleView = self.bubbleView {
                let showAtLeast: CGFloat = 50
                let middleCenter = CGPoint(x: bubbleView.frame.origin.x + bubbleView.frame.width / 2,
                                           y: bubbleView.frame.origin.y + bubbleView.frame.height - showAtLeast)
                let offset = bubbleView.superview!.convert(middleCenter, to: scrollView)
                self.scrollView!.setContentOffset(offset, animated: false)
            }
        }

        NotificationCenter.default.addObserver(self,
            selector: #selector(yapDatabaseModified),
            name: NSNotification.Name.YapDatabaseModified,
            object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        mediaMessageView?.viewWillAppear(animated)

        updateTextLayout()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        mediaMessageView?.viewWillDisappear(animated)
    }

    // MARK: - Create Views

    private func createViews() {
        view.backgroundColor = UIColor.white

        let scrollView = UIScrollView()
        scrollView.delegate = self
        self.scrollView = scrollView
        view.addSubview(scrollView)
        scrollView.autoPinWidthToSuperview(withMargin: 0)
        scrollView.autoPin(toTopLayoutGuideOf: self, withInset: 0)

        // See notes on how to use UIScrollView with iOS Auto Layout:
        //
        // https://developer.apple.com/library/content/releasenotes/General/RN-iOSSDK-6_0/
        let contentView = UIView.container()
        self.contentView = contentView
        scrollView.addSubview(contentView)
        contentView.autoPinLeadingToSuperview()
        contentView.autoPinTrailingToSuperview()
        contentView.autoPinEdge(toSuperviewEdge: .top)
        contentView.autoPinEdge(toSuperviewEdge: .bottom)
        scrollView.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let hasAttachment = message.attachmentIds.count > 0

        if hasAttachment {
            let footer = UIToolbar()
            footer.barTintColor = UIColor.ows_materialBlue()
            view.addSubview(footer)
            footer.autoPinWidthToSuperview(withMargin: 0)
            footer.autoPinEdge(.top, to: .bottom, of: scrollView)
            footer.autoPin(toBottomLayoutGuideOf: self, withInset: 0)

            footer.items = [
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareButtonPressed)),
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
            ]
        } else {
            scrollView.autoPin(toBottomLayoutGuideOf: self, withInset: 0)
        }

        updateContent()
    }

    private func updateContent() {
        guard let contentView = contentView else {
            owsFail("\(TAG) Missing contentView")
            return
        }

        // Remove any existing content views.
        for subview in contentView.subviews {
            subview.removeFromSuperview()
        }

        var rows = [UIView]()
        let contactsManager = Environment.getCurrent().contactsManager!
        let thread = message.thread

        // Content
        rows += contentRows()

        // Sender?
        if let incomingMessage = message as? TSIncomingMessage {
            let senderId = incomingMessage.authorId
            let senderName = contactsManager.contactOrProfileName(forPhoneIdentifier: senderId)
            rows.append(valueRow(name: NSLocalizedString("MESSAGE_METADATA_VIEW_SENDER",
                                                         comment: "Label for the 'sender' field of the 'message metadata' view."),
                                 value: senderName))
        }

        // Recipient(s)
        if let outgoingMessage = message as? TSOutgoingMessage {

            let isGroupThread = message.thread.isGroupThread()

            let recipientStatusGroups: [MessageRecipientStatus] = [
                .read,
                .uploading,
                .delivered,
                .sent,
                .sending,
                .failed
            ]
            for recipientStatusGroup in recipientStatusGroups {
                var groupRows = [UIView]()

                // TODO: It'd be nice to inset these dividers from the edge of the screen.
                let addDivider = {
                    let divider = UIView()
                    divider.backgroundColor = UIColor(white: 0.9, alpha: 1.0)
                    divider.autoSetDimension(.height, toSize: 0.5)
                    groupRows.append(divider)
                }

                for recipientId in thread.recipientIdentifiers {
                    let (recipientStatus, statusMessage) = MessageRecipientStatusUtils.recipientStatusAndStatusMessage(outgoingMessage: outgoingMessage, recipientId: recipientId, referenceView: self.view)

                    guard recipientStatus == recipientStatusGroup else {
                        continue
                    }

                    if groupRows.count < 1 {
                        if isGroupThread {
                            groupRows.append(valueRow(name: string(for: recipientStatusGroup),
                                                      value: ""))
                        }

                        addDivider()
                    }

                    let cell = ContactTableViewCell()
                    cell.configure(withRecipientId: recipientId, contactsManager: self.contactsManager)
                    let statusLabel = UILabel()
                    statusLabel.text = statusMessage
                    statusLabel.textColor = UIColor.ows_darkGray()
                    statusLabel.font = UIFont.ows_footnote()
                    statusLabel.sizeToFit()
                    cell.accessoryView = statusLabel
                    cell.autoSetDimension(.height, toSize: ContactTableViewCell.rowHeight())
                    cell.setContentHuggingLow()
                    cell.isUserInteractionEnabled = false
                    groupRows.append(cell)
                }

                if groupRows.count > 0 {
                    addDivider()

                    let spacer = UIView()
                    spacer.autoSetDimension(.height, toSize: 10)
                    groupRows.append(spacer)
                }

                Logger.verbose("\(groupRows.count) rows for \(recipientStatusGroup)")
                guard groupRows.count > 0 else {
                    continue
                }
                rows += groupRows
            }
        }

        rows.append(valueRow(name: NSLocalizedString("MESSAGE_METADATA_VIEW_SENT_DATE_TIME",
                                                     comment: "Label for the 'sent date & time' field of the 'message metadata' view."),
                             value: DateUtil.formatPastTimestampRelativeToNow(message.timestamp)))

        if message as? TSIncomingMessage != nil {
            rows.append(valueRow(name: NSLocalizedString("MESSAGE_METADATA_VIEW_RECEIVED_DATE_TIME",
                                                         comment: "Label for the 'received date & time' field of the 'message metadata' view."),
                                 value: DateUtil.formatPastTimestampRelativeToNow(message.timestampForSorting())))
        }

        rows += addAttachmentMetadataRows()

        // TODO: We could include the "disappearing messages" state here.

        var lastRow: UIView?
        for row in rows {
            contentView.addSubview(row)
            row.autoPinLeadingToSuperview()
            row.autoPinTrailingToSuperview()

            if let lastRow = lastRow {
                row.autoPinEdge(.top, to: .bottom, of: lastRow, withOffset: 5)
            } else {
                row.autoPinEdge(toSuperviewEdge: .top, withInset: 20)
            }

            lastRow = row
        }
        if let lastRow = lastRow {
            lastRow.autoPinEdge(toSuperviewEdge: .bottom, withInset: 20)
        }

        if let mediaMessageView = mediaMessageView {
            mediaMessageView.autoPinToSquareAspectRatio()
        }
    }

    private func displayableTextIfText() -> String? {
        let messageCellType = viewItem.messageCellType()
        guard messageCellType == .textMessage ||
            messageCellType == .oversizeTextMessage else {
                return nil
        }
        guard let displayableText = viewItem.displayableText() else {
                return nil
        }
        let messageBody = displayableText.fullText
        guard messageBody.characters.count > 0  else {
            return nil
        }
        return messageBody
    }

    private func contentRows() -> [UIView] {
        var rows = [UIView]()

        if let messageBody = displayableTextIfText() {

            self.messageBody = messageBody

            let isIncoming = self.message as? TSIncomingMessage != nil

            // UITextView can't render extremely long text due to constraints
            // on the size of its backing buffer, especially when we're 
            // embedding it "full-size' within a UIScrollView as we do in this view.
            //
            // Therefore we're doing something unusual here.  
            // See comments on updateTextLayout.
            let messageTextView = UITextView()
            self.messageTextView = messageTextView
            messageTextView.font = UIFont.ows_dynamicTypeBody()
            messageTextView.backgroundColor = UIColor.clear
            messageTextView.isOpaque = false
            messageTextView.isEditable = false
            messageTextView.isSelectable = true
            messageTextView.textContainerInset = UIEdgeInsets.zero
            messageTextView.contentInset = UIEdgeInsets.zero
            messageTextView.isScrollEnabled = true
            messageTextView.showsHorizontalScrollIndicator = false
            messageTextView.showsVerticalScrollIndicator = false
            messageTextView.isUserInteractionEnabled = false
            messageTextView.textColor = isIncoming ? UIColor.black : UIColor.white
            messageTextView.text = messageBody

            let bubbleImageData = isIncoming ? bubbleFactory.incoming : bubbleFactory.outgoing

            let messageTextProxyView = UIView()
            messageTextProxyView.layoutMargins = UIEdgeInsets.zero
            self.messageTextProxyView = messageTextProxyView
            messageTextProxyView.addSubview(messageTextView)
            messageTextView.autoPinWidthToSuperview()
            self.messageTextTopConstraint = messageTextView.autoPinEdge(toSuperviewEdge: .top, withInset: 0)
            self.messageTextHeightLayoutConstraint = messageTextView.autoSetDimension(.height, toSize:0)

            let leadingMargin: CGFloat = isIncoming ? 15 : 10
            let trailingMargin: CGFloat = isIncoming ? 10 : 15

            let bubbleView = UIImageView(image: bubbleImageData.messageBubbleImage)
            self.bubbleView = bubbleView

            bubbleView.layer.cornerRadius = 10
            bubbleView.addSubview(messageTextProxyView)

            messageTextProxyView.autoPinEdge(toSuperviewEdge: .leading, withInset: leadingMargin)
            messageTextProxyView.autoPinEdge(toSuperviewEdge: .trailing, withInset: trailingMargin)
            messageTextProxyView.autoPinHeightToSuperview(withMargin: 10)
            self.messageTextProxyViewHeightConstraint = messageTextProxyView.autoSetDimension(.height, toSize:0)

            let row = UIView()
            row.addSubview(bubbleView)
            bubbleView.autoPinHeightToSuperview()
            bubbleView.autoPinLeadingToSuperview(withMargin: 10)
            bubbleView.autoPinTrailingToSuperview(withMargin: 10)
            rows.append(row)
        } else if message.attachmentIds.count > 0 {
            rows += addAttachmentRows()
        } else {
            // Neither attachment nor body.
            owsFail("\(self.TAG) Message has neither attachment nor body.")
            rows.append(valueRow(name: NSLocalizedString("MESSAGE_METADATA_VIEW_NO_ATTACHMENT_OR_BODY",
                                                         comment: "Label for messages without a body or attachment in the 'message metadata' view."),
                                 value: ""))
        }

        let spacer = UIView()
        spacer.autoSetDimension(.height, toSize: 15)
        rows.append(spacer)

        return rows
    }

    private func addAttachmentRows() -> [UIView] {
        var rows = [UIView]()

        guard let attachmentId = message.attachmentIds[0] as? String else {
            owsFail("Invalid attachment")
            return rows
        }

        guard let attachment = TSAttachment.fetch(uniqueId: attachmentId) else {
            owsFail("Missing attachment")
            return rows
        }
        self.attachment = attachment

        guard let attachmentStream = attachment as? TSAttachmentStream else {
            rows.append(valueRow(name: NSLocalizedString("MESSAGE_METADATA_VIEW_ATTACHMENT_NOT_YET_DOWNLOADED",
                                                         comment: "Label for 'not yet downloaded' attachments in the 'message metadata' view."),
                                 value: ""))
            return rows
        }
        self.attachmentStream = attachmentStream

        if let filePath = attachmentStream.filePath() {
            dataSource = DataSourcePath.dataSource(withFilePath: filePath)
        }

        guard let dataSource = dataSource else {
            rows.append(valueRow(name: NSLocalizedString("MESSAGE_METADATA_VIEW_ATTACHMENT_MISSING_FILE",
                                                         comment: "Label for 'missing' attachments in the 'message metadata' view."),
                                 value: ""))
            return rows
        }

        let contentType = attachment.contentType
        if let dataUTI = MIMETypeUtil.utiType(forMIMEType: contentType) {
            let attachment = SignalAttachment(dataSource: dataSource, dataUTI: dataUTI)
            let mediaMessageView = MediaMessageView(attachment: attachment, mode: .small)
            mediaMessageView.backgroundColor = UIColor.white
            self.mediaMessageView = mediaMessageView
            rows.append(mediaMessageView)
        }
        return rows
    }

    private func addAttachmentMetadataRows() -> [UIView] {
        var rows = [UIView]()

        if let attachment = self.attachment {
            let contentType = attachment.contentType
            rows.append(valueRow(name: NSLocalizedString("MESSAGE_METADATA_VIEW_ATTACHMENT_MIME_TYPE",
                                                         comment: "Label for the MIME type of attachments in the 'message metadata' view."),
                                 value: contentType))

            if let sourceFilename = attachment.sourceFilename {
                rows.append(valueRow(name: NSLocalizedString("MESSAGE_METADATA_VIEW_SOURCE_FILENAME",
                                                             comment: "Label for the original filename of any attachment in the 'message metadata' view."),
                                     value: sourceFilename))
            }
        }

        if let dataSource = self.dataSource {
            let fileSize = dataSource.dataLength()
            rows.append(valueRow(name: NSLocalizedString("MESSAGE_METADATA_VIEW_ATTACHMENT_FILE_SIZE",
                                                         comment: "Label for file size of attachments in the 'message metadata' view."),
                                 value: ViewControllerUtils.formatFileSize(UInt(fileSize))))
        }

        return rows
    }

    private func nameLabel(text: String) -> UILabel {
        let label = UILabel()
        label.textColor = UIColor.black
        label.font = UIFont.ows_mediumFont(withSize: 14)
        label.text = text
        label.setContentHuggingHorizontalHigh()
        return label
    }

    private func valueLabel(text: String) -> UILabel {
        let label = UILabel()
        label.textColor = UIColor.black
        label.font = UIFont.ows_regularFont(withSize: 14)
        label.text = text
        label.setContentHuggingHorizontalLow()
        return label
    }

    private func valueRow(name: String, value: String, subtitle: String = "") -> UIView {
        let row = UIView.container()
        let nameLabel = self.nameLabel(text: name)
        let valueLabel = self.valueLabel(text: value)
        row.addSubview(nameLabel)
        row.addSubview(valueLabel)
        nameLabel.autoPinLeadingToSuperview(withMargin: 20)
        valueLabel.autoPinTrailingToSuperview(withMargin: 20)
        valueLabel.autoPinLeading(toTrailingOf: nameLabel, margin: 10)
        nameLabel.autoPinEdge(toSuperviewEdge: .top)
        valueLabel.autoPinEdge(toSuperviewEdge: .top)

        if subtitle.characters.count > 0 {
            let subtitleLabel = self.valueLabel(text: subtitle)
            subtitleLabel.textColor = UIColor.ows_darkGray()
            row.addSubview(subtitleLabel)
            subtitleLabel.autoPinTrailingToSuperview()
            subtitleLabel.autoPinLeading(toTrailingOf: nameLabel, margin: 10)
            subtitleLabel.autoPinEdge(.top, to: .bottom, of: valueLabel, withOffset: 1)
            subtitleLabel.autoPinEdge(toSuperviewEdge: .bottom)
        } else if value.characters.count > 0 {
            valueLabel.autoPinEdge(toSuperviewEdge: .bottom)
        } else {
            nameLabel.autoPinEdge(toSuperviewEdge: .bottom)
        }

        return row
    }

    // MARK: - Actions

    func shareButtonPressed() {
        if let messageBody = messageBody {
            UIPasteboard.general.string = messageBody
            return
        }

        guard let attachmentStream = attachmentStream else {
            Logger.error("\(TAG) Message has neither attachment nor message body.")
            return
        }
        AttachmentSharing.showShareUI(forAttachment: attachmentStream)
    }

    func copyToPasteboard() {
        if let messageBody = messageBody {
            UIPasteboard.general.string = messageBody
            return
        }

        guard let attachmentStream = attachmentStream else {
            Logger.error("\(TAG) Message has neither attachment nor message body.")
            return
        }
        guard let utiType = MIMETypeUtil.utiType(forMIMEType: attachmentStream.contentType) else {
            Logger.error("\(TAG) Attachment has invalid MIME type: \(attachmentStream.contentType).")
            return
        }
        guard let dataSource = dataSource else {
            Logger.error("\(TAG) Attachment missing data source.")
            return
        }
        let data = dataSource.data()
        UIPasteboard.general.setData(data, forPasteboardType: utiType)
    }

    // MARK: - Actions

    // This method should be called after self.databaseConnection.beginLongLivedReadTransaction().
    private func updateDBConnectionAndMessageToLatest() {

        AssertIsOnMainThread()

        self.databaseConnection.read { transaction in
            guard let newMessage = TSInteraction.fetch(uniqueId: self.message.uniqueId, transaction: transaction) as? TSMessage else {
                Logger.error("\(self.TAG) Couldn't reload message.")
                return
            }
            self.message = newMessage
        }
    }

    internal func yapDatabaseModified(notification: NSNotification) {
        AssertIsOnMainThread()

        let notifications = self.databaseConnection.beginLongLivedReadTransaction()

        guard self.databaseConnection.hasChange(forKey: message.uniqueId,
                                                 inCollection: TSInteraction.collection(),
                                                 in: notifications) else {
                                                    Logger.debug("\(TAG) No relevant changes.")
                                                    return
        }

        updateDBConnectionAndMessageToLatest()

        updateContent()
    }

    private func string(for messageRecipientStatus: MessageRecipientStatus) -> String {
        switch messageRecipientStatus {
        case .uploading:
            return NSLocalizedString("MESSAGE_METADATA_VIEW_MESSAGE_STATUS_UPLOADING",
                              comment: "Status label for messages which are uploading.")
        case .sending:
            return NSLocalizedString("MESSAGE_METADATA_VIEW_MESSAGE_STATUS_SENDING",
                              comment: "Status label for messages which are sending.")
        case .sent:
            return NSLocalizedString("MESSAGE_METADATA_VIEW_MESSAGE_STATUS_SENT",
                              comment: "Status label for messages which are sent.")
        case .delivered:
            return NSLocalizedString("MESSAGE_METADATA_VIEW_MESSAGE_STATUS_DELIVERED",
                              comment: "Status label for messages which are delivered.")
        case .read:
            return NSLocalizedString("MESSAGE_METADATA_VIEW_MESSAGE_STATUS_READ",
                              comment: "Status label for messages which are read.")
        case .failed:
            return NSLocalizedString("MESSAGE_METADATA_VIEW_MESSAGE_STATUS_FAILED",
                              comment: "Status label for messages which are failed.")
        }
    }

    // MARK: - Text Layout

    // UITextView can't render extremely long text due to constraints on the size
    // of its backing buffer, especially when we're embedding it "full-size' 
    // within a UIScrollView as we do in this view.  Therefore if we do the naive
    // thing and embed a full-size UITextView inside our UIScrollView, it will 
    // fail to render any text if the text message is sufficiently long.
    //
    // Therefore we're doing something unusual.  
    //
    // * We use an empty UIView "messageTextProxyView" as a placeholder for the
    //   the UITextView.  It has the size and position of where the UITextView
    //   would be normally.
    // * We use a UITextView inside that proxy that is just large enough to
    //   render the content onscreen. We then move it around within the proxy
    //   bounds to render the parts of the proxy which are onscreen.
    private func updateTextLayout() {
        guard let messageTextView = messageTextView else {
            return
        }
        guard let messageTextProxyView = messageTextProxyView else {
            owsFail("\(TAG) Missing messageTextProxyView")
            return
        }
        guard let messageTextTopConstraint = messageTextTopConstraint else {
            owsFail("\(TAG) Missing messageTextProxyView")
            return
        }
        guard let messageTextHeightLayoutConstraint = messageTextHeightLayoutConstraint else {
            owsFail("\(TAG) Missing messageTextProxyView")
            return
        }
        guard let messageTextProxyViewHeightConstraint = messageTextProxyViewHeightConstraint else {
            owsFail("\(TAG) Missing messageTextProxyView")
            return
        }
        guard let scrollView = scrollView else {
            owsFail("\(TAG) Missing scrollView")
            return
        }
        guard let contentView = contentView else {
            owsFail("\(TAG) Missing contentView")
            return
        }

        if messageTextView.width() != messageTextProxyView.width() {
            owsFail("\(TAG) messageTextView.width \(messageTextView.width) != messageTextProxyView.width \(messageTextProxyView.width)")
        }

        // Measure the total text size.
        let textSize = messageTextView.sizeThatFits(CGSize(width:messageTextView.width(), height:CGFloat.greatestFiniteMagnitude))
        // Measure the size of the scroll view viewport.
        let scrollViewSize = scrollView.frame.size
        // Obtain the current scroll view content offset (scroll state).
        let scrollViewContentOffset = scrollView.contentOffset
        // Obtain the location of the text view proxy relative to the content view.
        let textProxyOffset = contentView.convert(CGPoint.zero, from:messageTextProxyView)

        // 1. The text proxy should always be sized large enough to hold the
        //    entire text content.
        let messageTextProxyViewHeight = textSize.height
        messageTextProxyViewHeightConstraint.constant = messageTextProxyViewHeight

        // 2. We only want to render a single screenful of text content at a time.
        //    The height of the text view should reflect the height of the scrollview's
        //    viewport.
        let messageTextViewHeight = min(textSize.height, scrollViewSize.height)
        messageTextHeightLayoutConstraint.constant = messageTextViewHeight

        // 3. We want to move the text view around within the proxy in response to 
        //    scroll state changes so that it can render the part of the proxy which
        //    is on screen.
        let minMessageTextViewY = CGFloat(0)
        let maxMessageTextViewY = messageTextProxyViewHeight - messageTextViewHeight
        let rawMessageTextViewY = -textProxyOffset.y + scrollViewContentOffset.y
        let messageTextViewY = max(minMessageTextViewY, min(maxMessageTextViewY, rawMessageTextViewY))
        messageTextTopConstraint.constant = messageTextViewY

        // 4. We want to scroll the text view's content so that the text view
        //    renders the appropriate content for the scrollview's scroll state.
        messageTextView.contentOffset = CGPoint(x:0, y:messageTextViewY)
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        Logger.verbose("\(TAG) scrollViewDidScroll")

        updateTextLayout()
    }
}