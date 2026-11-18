/// Menu presentation changes only through explicit activation or dismissal.
/// Hover state belongs to button styling and cannot open or close a menu.
struct ClickMenuInteraction {
    var isPresented = false
    private(set) var takesFocus = false
    mutating func clickTrigger() {
        isPresented.toggle()
        takesFocus = isPresented
    }
    mutating func didDismiss() {
        isPresented = false
        takesFocus = false
    }
}
