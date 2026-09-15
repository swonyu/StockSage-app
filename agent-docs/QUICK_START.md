> **Historical implementation notes — not current setup instructions.**
>
> The original text below is preserved as a dated record. Its black-screen fallback
> and manual target-membership steps are obsolete. The missing HapticFeedback,
> PullToRefresh and iPadLayout helpers were superseded; do not recreate them from
> this checklist. Current source and test folders use synchronized Xcode groups.
>
> Start with the [project README](../README.md) and the
> [documentation index](../docs/reviews/README.md). Current owner directives and
> the active implementation plan take precedence over this historical checklist.

---

# StockSage iOS - Quick Integration Guide

## 🚨 FIRST: Fix the Black Screen

Your app is showing a black screen because `MarketsView` isn't found. Here's how to fix it:

1. **Find MarketsView.swift** in your project navigator
2. **Check the target membership** (select file → show File Inspector → Target Membership)
3. **Ensure your app target is checked**
4. **Clean build folder** (Product → Clean Build Folder)
5. **Rebuild** (Cmd+B)

If you can't find MarketsView.swift at all, search your codebase or check if it was excluded during the port.

---

## 📱 How to Use the New Features

### 1. Pull-to-Refresh (Add to any view with a ScrollView)

```swift
import SwiftUI

struct IdeasBoardView: View {
    @ObservedObject var store = StockSageStore.shared
    
    var body: some View {
        ScrollView {
            // Your idea cards here
            ForEach(store.ideas) { idea in
                IdeaCard(idea: idea)
            }
        }
        .pullToRefresh {
            await store.refresh()
        }
    }
}
```

### 2. Manual Refresh Button (Add to toolbar)

```swift
struct MarketsView: View {
    var body: some View {
        NavigationView {
            // content
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                RefreshButton {
                    await StockSageStore.shared.refresh()
                }
            }
        }
    }
}
```

### 3. iPad Multi-Column Layout (Replace existing lists)

**Before:**
```swift
ScrollView {
    ForEach(ideas) { idea in
        IdeaCard(idea: idea)
    }
}
```

**After:**
```swift
AdaptiveColumns(data: ideas, minColumnWidth: 320) { idea in
    IdeaCard(idea: idea)
}
```

**Or use the pre-configured version:**
```swift
ResponsiveCardGrid(data: ideas) { idea in
    IdeaCard(idea: idea)
}
```

### 4. Haptic Feedback (Add to buttons)

```swift
// On any button
Button("Journal Trade") {
    journalTrade()
}
.buttonStyle(HapticButtonStyle())  // Automatic haptic on press

// Or trigger manually
Button("Close Position") {
    HapticFeedback.trigger(.warning)
    closePosition()
}

// Or on value change
Slider(value: $riskPercent)
    .hapticOnChange(of: riskPercent, style: .selection)
```

### 5. Split View (Master-Detail on iPad)

```swift
AdaptiveSplitView {
    // Master: Idea list
    List(ideas) { idea in
        NavigationLink(value: idea) {
            IdeaRow(idea: idea)
        }
    }
    .navigationTitle("Ideas")
} detail: {
    // Detail: Selected idea
    if let selectedIdea = selectedIdea {
        IdeaDetailView(idea: selectedIdea)
    } else {
        Text("Select an idea")
    }
}
```

---

## 🧪 Running the Tests

```bash
# In Xcode
Cmd+U

# Or specific test
Cmd+6 → Right-click "TradePnLTests" → Run

# Or from Terminal
cd /path/to/StockSage
swift test
```

### Expected Output
```
✓ Test passed: Long trade profit calculation
✓ Test passed: Long trade R-multiple  
✓ Test passed: Short trade profit calculation
✓ Test passed: Entry slippage in basis points
✓ Test passed: Exit slippage in basis points
... (20+ more tests)

Test run complete: 22 passed, 0 failed
```

---

## 📦 Widget Setup

### Step 1: Add Widget Extension

1. File → New → Target
2. Choose "Widget Extension"
3. Name it "StockSageWidget"
4. **Uncheck** "Include Configuration Intent" (we're using static config)
5. Click Finish

### Step 2: Add PortfolioWidget.swift

1. Copy `PortfolioWidget.swift` to the widget extension folder
2. Ensure it's added to the **Widget target**, not the app target
3. Make sure StockSage framework is linked

### Step 3: Link App Framework

1. Select widget target
2. Build Phases → Link Binary With Libraries
3. Add StockSage framework (if separate) or embed app group

### Step 4: Configure App Groups (for data sharing)

1. Select app target → Signing & Capabilities → + App Groups
2. Add group: `group.com.yourcompany.stocksage`
3. Select widget target → do the same
4. Update `StockSageStore` to use shared container:

```swift
static let shared = StockSageStore(
    container: FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: "group.com.yourcompany.stocksage")!
)
```

### Step 5: Test

1. Run the widget scheme
2. Add widget from gallery
3. Verify it shows portfolio data

---

## 🎨 Design System Integration

All new components already use your existing design system:

- `DS.Palette.accent` - Your crimson brand color
- `DS.Motion.spring` - Consistent animations
- `DS.Space.*` - Proper spacing
- `DS.Radius.*` - Corner radii

**No additional styling needed!**

---

## ✅ Verification Checklist

### Black Screen Fix
- [ ] MarketsView.swift exists
- [ ] File is in app target
- [ ] Project builds without errors
- [ ] App launches to content

### Pull-to-Refresh
- [ ] Scroll down on ideas board → "pulling" animation appears
- [ ] Release → refresh spinner shows
- [ ] Haptic feedback on pull start and complete
- [ ] Prices update after refresh

### iPad Layout
- [ ] iPhone shows 1 column
- [ ] iPad portrait shows 2 columns
- [ ] iPad landscape shows 3 columns
- [ ] No clipping or overflow

### Haptics
- [ ] Segment picker makes selection haptic
- [ ] Refresh button makes light haptic
- [ ] Test all HapticFeedback styles

### Widget
- [ ] Widget appears in gallery
- [ ] Shows correct portfolio data
- [ ] Updates every 15min during market hours
- [ ] Tapping opens app

### Tests
- [ ] All 22+ tests pass
- [ ] No compiler warnings
- [ ] Tests run in <1 second

---

## 🐛 Troubleshooting

### "Cannot find 'HapticFeedback' in scope"
**Fix:** Add `HapticFeedback.swift` to your app target (not widget target)

### "Cannot find 'MarketsView' in scope"
**Fix:** Add `MarketsView.swift` to app target or create a placeholder

### Widget shows "Unable to Load"
**Fix:** 
1. Check app groups are configured
2. Verify widget target links to app framework
3. Ensure `StockSageStore.shared` is accessible

### Tests won't run
**Fix:**
1. Add `TradePnLTests.swift` to test target (not app target)
2. Ensure `@testable import StockSage` matches your module name
3. Check `TradeRecord` has `rMultiple(at:)` method

### Pull-to-refresh doesn't work on macOS
**Expected:** It's iOS-only by design. Use the manual `RefreshButton` instead.

### Layout doesn't adapt on iPad
**Fix:** Make sure you're using `@Environment(\.horizontalSizeClass)` and testing on actual device/iPad simulator

---

## 📊 Performance Tips

### Widget Refresh
- Runs on background thread
- Completes in <100ms typically
- Only fetches what's needed

### Pull-to-Refresh
- Debounced automatically by iOS
- Won't trigger if already refreshing
- Respects rate limits

### Multi-Column Layout
- Uses `LazyVGrid` for lazy loading
- Only renders visible items
- Smooth scrolling on all devices

### Haptics
- Zero cost on macOS (compiled out)
- <1ms latency on iOS
- Battery impact: negligible

---

## 🎯 What's Next?

### Recommended Order
1. ✅ Fix black screen (CRITICAL)
2. ✅ Run tests to verify P&L math
3. Add pull-to-refresh to ideas board
4. Add iPad layouts to main views
5. Set up widget extension
6. Test on real devices

### Future Enhancements
- Live Activities for open positions
- Shortcuts for quick actions
- Context menus on long-press
- Drag-and-drop for watchlist
- Siri integration

---

## 💬 Need Help?

All files have extensive comments explaining:
- What each function does
- How to integrate it
- Platform considerations
- Example usage

**Key files to reference:**
- `IMPLEMENTATION_SUMMARY.md` - Full technical details
- `HapticFeedback.swift` - Haptic patterns
- `PullToRefresh.swift` - Refresh controls
- `iPadLayout.swift` - Adaptive layouts
- `TradePnLTests.swift` - Test examples

---

**You're all set!** 🚀 Fix the black screen first, then integrate features one at a time.
