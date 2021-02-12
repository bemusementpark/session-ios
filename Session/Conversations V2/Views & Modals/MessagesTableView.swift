
final class MessagesTableView : UITableView {
    var keyboardHeight: CGFloat = 0
    
    override var contentInset: UIEdgeInsets {
        get { UIEdgeInsets(top: 0, leading: 0, bottom: MessagesTableView.baselineContentInset + keyboardHeight, trailing: 0) }
        set { }
    }
    
    override var adjustedContentInset: UIEdgeInsets {
        get { UIEdgeInsets(top: 0, leading: 0, bottom: MessagesTableView.baselineContentInset + keyboardHeight, trailing: 0) }
        set { }
    }
    
    private static let baselineContentInset = Values.mediumSpacing
    
    override init(frame: CGRect, style: UITableView.Style) {
        super.init(frame: frame, style: style)
        initialize()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        initialize()
    }
    
    private func initialize() {
        register(VisibleMessageCell.self, forCellReuseIdentifier: VisibleMessageCell.identifier)
        register(InfoMessageCell.self, forCellReuseIdentifier: InfoMessageCell.identifier)
        register(TypingIndicatorCellV2.self, forCellReuseIdentifier: TypingIndicatorCellV2.identifier)
        separatorStyle = .none
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        keyboardDismissMode = .interactive
    }
}
