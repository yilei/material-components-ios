// Copyright 2018-present the Material Components for iOS authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "MDCBottomDrawerContainerViewController.h"

#import "MDCBottomDrawerHeader.h"
#import "MaterialShadowLayer.h"
#import "MaterialUIMetrics.h"

static const CGFloat kVerticalShadowAnimationDistance = 10.f;
static const CGFloat kVerticalDistanceThresholdForDismissal = 40.f;
static const CGFloat kInitialDrawerHeightFactor = 0.5f;
static const CGFloat kHeaderAnimationDistanceAddedDistanceFromTopSafeAreaInset =
    20.f;
static const CGFloat kDragVelocityThresholdForHidingDrawer = -2.f;
static NSString *const kContentOffsetKeyPath = @"contentOffset";

static UIColor *DrawerShadowColor(void) {
  return [[UIColor blackColor] colorWithAlphaComponent:0.2f];
}

@interface MDCBottomDrawerContainerViewController (LayoutCalculations)

/**
 The vertical distance of the content header from the top of the window
 when the drawer is first displayed.
 When no content header is displayed, equal to the top inset of the content.
 */
@property(nonatomic, readonly) CGFloat contentHeaderTopInset;

// The content height surplus at the moment the drawer is first displayed.
@property(nonatomic, readonly) CGFloat contentHeightSurplus;

// An added height for the scroll view bottom inset.
@property(nonatomic, readonly) CGFloat addedContentHeight;

// Updates and caches the layout calculations.
- (void)cacheLayoutCalculations;

/**
 Returns the percentage of the transition animation for a given content offset.
 The transition animation, as defined here, occurs either when the content reaches fullscreen or
 when the entire content is displayed, whichever comes first.

 @param contentOffset The content offset.
 @param offset A value by which the triggering point of the animation should be shifted.
 A positive value will cause the animation to start earlier, while a negative value will cause
 the animation to start later.
 @param distance The distance the scroll view scrolls from the moment the animation starts
 and until it completes.
 */
- (CGFloat)transitionPercentageForContentOffset:(CGPoint)contentOffset
                                         offset:(CGFloat)offset
                                       distance:(CGFloat)distance;

/**
 Checks the given target content offset to ensure the target offset will not cause the drawer to
 end up in the middle of the header animation when the dragging ends. When needed, returns an
 updated vertical target content offset that ensures the header animation is in a defined state.
 Otherwise, returns NSNotFound.
 */
- (CGFloat)midAnimationScrollToPositionForOffset:(CGPoint)targetContentOffset;

@end

@interface MDCBottomDrawerContainerViewController (LayoutValues)

// The presenting view's bounds after it has been standardized.
@property(nonatomic, readonly) CGRect presentingViewBounds;

// Whether the content reaches to fullscreen.
@property(nonatomic, readonly) BOOL contentReachesFullscreen;

// Whether the content height exceeds the visible height when it's first displayed.
@property(nonatomic, readonly) BOOL contentScrollsToReveal;

// The top header height when the drawer is displayed in fullscreen.
@property(nonatomic, readonly) CGFloat topHeaderHeight;

// The content header height when the drawer is first displayed.
@property(nonatomic, readonly) CGFloat contentHeaderHeight;

// The vertical content offset where the transition animation completes.
@property(nonatomic, readonly) CGFloat transitionCompleteContentOffset;

// The headers animation distance.
@property(nonatomic, readonly) CGFloat headerAnimationDistance;

// The distance to top threshold for adding extra content height.
@property(nonatomic, readonly) CGFloat addedContentHeightThreshold;

@end

@interface MDCBottomDrawerContainerViewController () <UIScrollViewDelegate>

// Whether the scroll view is observed via KVO.
@property(nonatomic) BOOL scrollViewObserved;

// The scroll view is currently being dragged towards bottom.
@property(nonatomic) BOOL scrollViewIsDraggedToBottom;

// The scroll view has started its current drag from fullscreen.
@property(nonatomic) BOOL scrollViewBeganDraggingFromFullscreen;

// Whether the drawer is currently shown in fullscreen.
@property(nonatomic) BOOL currentlyFullscreen;

// Views:

// The main scroll view.
@property(nonatomic, readonly) UIScrollView *scrollView;

// View that functions as the superview of |scrollView|. Used to clip the top of the scroll view.
@property(nonatomic, readonly) UIView *scrollViewClippingView;

// The top header bottom shadow layer.
@property(nonatomic) MDCShadowLayer *headerShadowLayer;

@end

@implementation MDCBottomDrawerContainerViewController {
  UIScrollView *_scrollView;
  UIView *_scrollViewClippingView;
  CGFloat _contentHeaderTopInset;
  CGFloat _contentHeightSurplus;
  CGFloat _addedContentHeight;
}

- (instancetype)initWithOriginalPresentingViewController:
    (UIViewController *)originalPresentingViewController
                                      trackingScrollView:(UIScrollView *)trackingScrollView {
  self = [super initWithNibName:nil bundle:nil];
  if (self) {
    _originalPresentingViewController = originalPresentingViewController;
    _contentHeaderTopInset = NSNotFound;
    _contentHeightSurplus = NSNotFound;
    _addedContentHeight = NSNotFound;
    _trackingScrollView = trackingScrollView;
  }
  return self;
}

- (void)dealloc {
  [self removeScrollViewObserver];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)hideDrawer {
  [self.originalPresentingViewController dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark UIGestureRecognizerDelegate (Public)

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
  CGFloat locationInView = [touch locationInView:nil].y;
  CGFloat contentOriginY = self.headerViewController.view != nil
                               ? self.headerViewController.view.frame.origin.y
                               : self.contentViewController.view.frame.origin.y;
  CGFloat contentOriginYConverted =
      [(self.headerViewController.view.superview ?: self.contentViewController.view.superview)
          convertPoint:CGPointMake(0, contentOriginY)
                toView:nil]
          .y;
  return locationInView < contentOriginYConverted;
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  if ([object isKindOfClass:[UIScrollView class]]) {
    CGPoint contentOffset = [(NSValue *)[change objectForKey:NSKeyValueChangeNewKey] CGPointValue];
    CGPoint oldContentOffset =
        [(NSValue *)[change objectForKey:NSKeyValueChangeOldKey] CGPointValue];
    self.scrollViewIsDraggedToBottom = contentOffset.y == oldContentOffset.y
                                           ? self.scrollViewIsDraggedToBottom
                                           : contentOffset.y < oldContentOffset.y;

    [self updateViewWithContentOffset:contentOffset];

    if (self.trackingScrollView != nil) {
      [self updateContentOffsetForPerformantScrolling:contentOffset.y];
    }
  }
}

- (void)updateContentOffsetForPerformantScrolling:(CGFloat)contentYOffset {
  CGFloat topAreaInsetForHeader = (self.headerViewController ? MDCDeviceTopSafeAreaInset() : 0);
  CGFloat drawerOffset = self.contentHeaderTopInset - topAreaInsetForHeader;
  CGFloat headerHeightWithoutInset = self.contentHeaderHeight - topAreaInsetForHeader;
  CGFloat contentDiff = contentYOffset - drawerOffset;
  CGFloat maxScrollOrigin = self.trackingScrollView.contentSize.height -
                            CGRectGetHeight(self.presentingViewBounds) + headerHeightWithoutInset;
  BOOL scrollingUpInFull = contentDiff < 0 && CGRectGetMinY(self.trackingScrollView.bounds) > 0;
  if (CGRectGetMinY(self.scrollView.bounds) >= drawerOffset || scrollingUpInFull) {
    // If we reach full screen or if we are scrolling up after being in full screen.
    if (CGRectGetMinY(self.trackingScrollView.bounds) < maxScrollOrigin || scrollingUpInFull) {
      // If we still didn't reach the end of the content, or if we are scrolling up after reaching
      // the end of the content.

      // Update the drawer's scrollView's offset to be static so the content will scroll instead.
      CGRect scrollViewBounds = self.scrollView.bounds;
      scrollViewBounds.origin.y = drawerOffset;
      self.scrollView.bounds = scrollViewBounds;

      // Make sure the drawer's scrollView's content size is the full size of the content
      CGSize scrollViewContentSize = self.presentingViewBounds.size;
      scrollViewContentSize.height += self.contentHeightSurplus;
      self.scrollView.contentSize = scrollViewContentSize;

      // Update the main content view's scrollView offset
      CGRect contentViewBounds = self.trackingScrollView.bounds;
      contentViewBounds.origin.y += contentDiff;
      contentViewBounds.origin.y = MIN(maxScrollOrigin, MAX(CGRectGetMinY(contentViewBounds), 0));
      self.trackingScrollView.bounds = contentViewBounds;
    } else {
      if (self.trackingScrollView.contentSize.height >=
          CGRectGetHeight(self.trackingScrollView.frame)) {
        // Have the drawer's scrollView's content size be static so it will bounce when reaching the
        // end of the content.
        CGSize scrollViewContentSize = self.scrollView.contentSize;
        scrollViewContentSize.height =
            drawerOffset + CGRectGetHeight(self.scrollView.frame) + 2 * topAreaInsetForHeader;
        self.scrollView.contentSize = scrollViewContentSize;
      }
    }
  }
}

- (void)addScrollViewObserver {
  if (self.scrollViewObserved) {
    return;
  }
  self.scrollViewObserved = YES;
  [self.scrollView addObserver:self
                    forKeyPath:kContentOffsetKeyPath
                       options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                       context:nil];
}

- (void)removeScrollViewObserver {
  if (!self.scrollViewObserved) {
    return;
  }
  self.scrollViewObserved = NO;
  [self.scrollView removeObserver:self forKeyPath:kContentOffsetKeyPath];
}

#pragma mark UIViewController

- (void)viewDidLoad {
  [super viewDidLoad];

  [self setUpContentHeader];

  self.view.backgroundColor = [UIColor clearColor];

  [self.view addSubview:self.scrollViewClippingView];
  [self.scrollViewClippingView addSubview:self.scrollView];

  // Top header shadow layer starts as hidden.
  self.headerShadowLayer.hidden = YES;

  // Set up the content.
  if (self.contentViewController) {
    [self addChildViewController:self.contentViewController];
    [self.scrollView addSubview:self.contentViewController.view];
    [self.contentViewController didMoveToParentViewController:self];
  }
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  [self addScrollViewObserver];

  // Scroll view should not update its content insets implicitly.
#if defined(__IPHONE_11_0) && (__IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_11_0)
  if (@available(iOS 11.0, *)) {
    self.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.scrollView.insetsLayoutMarginsFromSafeArea = NO;
  }
#endif  // defined(__IPHONE_11_0) && (__IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_11_0)
}

- (void)viewWillLayoutSubviews {
  [super viewWillLayoutSubviews];

  // Layout the clipping view and the scroll view.
  if (self.currentlyFullscreen) {
    CGRect scrollViewClippingViewFrame = self.presentingViewBounds;
    scrollViewClippingViewFrame.origin.y = self.topHeaderHeight;
    scrollViewClippingViewFrame.size.height -= self.topHeaderHeight;
    self.scrollViewClippingView.frame = scrollViewClippingViewFrame;
    CGRect scrollViewFrame = self.presentingViewBounds;
    scrollViewFrame.origin.y = -self.topHeaderHeight;
    self.scrollView.frame = scrollViewFrame;
  } else {
    CGRect scrollViewFrame = self.presentingViewBounds;
    if (self.animatingPresentation) {
      CGFloat heightSurplusForSpringAnimationOvershooting =
          self.presentingViewBounds.size.height / 2.f;
      scrollViewFrame.size.height += heightSurplusForSpringAnimationOvershooting;
    }
    self.scrollViewClippingView.frame = scrollViewFrame;
    self.scrollView.frame = scrollViewFrame;
  }

  // Layout the top header's bottom shadow.
  [self setUpHeaderBottomShadowIfNeeded];
  self.headerShadowLayer.frame = self.headerViewController.view.bounds;

  // Set the scroll view's content size.
  CGSize scrollViewContentSize = self.presentingViewBounds.size;
  scrollViewContentSize.height += self.contentHeightSurplus;
  self.scrollView.contentSize = scrollViewContentSize;

  // Layout the main content view.
  CGRect contentViewFrame = self.scrollView.bounds;
  NSLog(@"%f", self.contentHeaderTopInset);
  contentViewFrame.origin.y = self.contentHeaderTopInset + self.contentHeaderHeight;
  if (self.trackingScrollView != nil) {
    contentViewFrame.size.height -=
        (self.contentHeaderHeight - (self.headerViewController ? MDCDeviceTopSafeAreaInset() : 0));
  } else {
    contentViewFrame.size.height = self.contentViewController.preferredContentSize.height;
  }
  self.contentViewController.view.frame = contentViewFrame;
  if (self.trackingScrollView != nil) {
    contentViewFrame.origin.y = self.trackingScrollView.frame.origin.y;
    self.trackingScrollView.frame = contentViewFrame;
  }

  [self.headerViewController.view.superview bringSubviewToFront:self.headerViewController.view];
  [self updateViewWithContentOffset:self.scrollView.contentOffset];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];

  [self removeScrollViewObserver];
  [self.headerShadowLayer removeFromSuperlayer];
  self.headerShadowLayer = nil;
}

#pragma mark Set ups (Private)

- (void)setUpContentHeader {
  if (!self.headerViewController) {
    return;
  }

  [self addChildViewController:self.headerViewController];
  if ([self.headerViewController respondsToSelector:@selector(updateDrawerHeaderTransitionRatio:)]) {
    [self.headerViewController updateDrawerHeaderTransitionRatio:0];
  }

  // Ensures the content header view has a sensible size so its subview layout correctly
  // before the drawer presentation animation.
  CGRect headerViewFrame = self.presentingViewBounds;
  headerViewFrame.size.height = self.contentHeaderHeight;
  self.headerViewController.view.frame = headerViewFrame;

  [self.scrollView addSubview:self.headerViewController.view];
  [self.headerViewController didMoveToParentViewController:self];
}

- (void)setUpHeaderBottomShadowIfNeeded {
  if (self.headerShadowLayer) {
    return;
  }

  self.headerShadowLayer = [[MDCShadowLayer alloc] init];
  self.headerShadowLayer.elevation = MDCShadowElevationNavDrawer;
  self.headerShadowLayer.shadowColor = DrawerShadowColor().CGColor;
  [self.headerViewController.view.layer addSublayer:self.headerShadowLayer];
  self.headerShadowLayer.hidden = YES;
}

#pragma mark Content Offset Adaptions (Private)

- (void)updateViewWithContentOffset:(CGPoint)contentOffset {
  CGFloat headerTransitionToTop =
      contentOffset.y >= self.contentHeaderTopInset
          ? 1.f
          : [self transitionPercentageForContentOffset:contentOffset
                                                offset:0.f
                                              distance:self.headerAnimationDistance];
  self.currentlyFullscreen =
      self.contentReachesFullscreen && headerTransitionToTop >= 1.f - FLT_EPSILON;
  CGFloat fullscreenHeaderHeight =
      self.contentReachesFullscreen ? self.topHeaderHeight : [self contentHeaderHeight];

  [self updateContentHeaderWithTransitionToTop:headerTransitionToTop
                        fullscreenHeaderHeight:fullscreenHeaderHeight];
  [self updateTopHeaderBottomShadowWithContentOffset:contentOffset];
}

- (void)updateContentHeaderWithTransitionToTop:(CGFloat)headerTransitionToTop
                        fullscreenHeaderHeight:(CGFloat)fullscreenHeaderHeight {
  if (!self.headerViewController) {
    return;
  }

  UIView *contentHeaderView = self.headerViewController.view;
  BOOL contentReachesFullscreen = self.contentReachesFullscreen;

  if ([self.headerViewController
       respondsToSelector:@selector(updateDrawerHeaderTransitionRatio:)]) {
    [self.headerViewController
        updateDrawerHeaderTransitionRatio:contentReachesFullscreen ? headerTransitionToTop : 0.f];
  }
  CGFloat contentHeaderHeight = self.contentHeaderHeight;
  CGFloat headersDiff = fullscreenHeaderHeight - contentHeaderHeight;
  CGFloat contentHeaderViewHeight = contentHeaderHeight + headerTransitionToTop * headersDiff;

  if (self.currentlyFullscreen && contentHeaderView.superview != self.view) {
    // The content header should be located statically at the top of the drawer when the drawer
    // is shown in fullscreen.
    [contentHeaderView removeFromSuperview];
    [self.view addSubview:contentHeaderView];
    self.scrollViewClippingView.clipsToBounds = YES;
    [self.view setNeedsLayout];
  } else if (!self.currentlyFullscreen && contentHeaderView.superview != self.scrollView) {
    // The content header should be scrolled together with the rest of the content when the drawer
    // is not in fullscreen.
    [contentHeaderView removeFromSuperview];
    [self.scrollView addSubview:contentHeaderView];
    self.scrollViewClippingView.clipsToBounds = NO;
    [self.view setNeedsLayout];
  }
  CGFloat contentHeaderViewWidth = self.presentingViewBounds.size.width;
  CGFloat contentHeaderViewTop =
      self.currentlyFullscreen ? 0.f
                               : self.contentHeaderTopInset - headerTransitionToTop * headersDiff;
  contentHeaderView.frame =
      CGRectMake(0, contentHeaderViewTop, contentHeaderViewWidth, contentHeaderViewHeight);
}

- (void)updateTopHeaderBottomShadowWithContentOffset:(CGPoint)contentOffset {
  self.headerShadowLayer.hidden = !self.currentlyFullscreen;
  if (!self.headerShadowLayer.hidden) {
    self.headerShadowLayer.opacity = (float)[self
        transitionPercentageForContentOffset:contentOffset
                                      offset:-kVerticalShadowAnimationDistance
                                    distance:kVerticalShadowAnimationDistance];
  }
}

#pragma mark Getters (Private)

- (UIScrollView *)scrollView {
  if (!_scrollView) {
    _scrollView = [[UIScrollView alloc] init];
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.backgroundColor = [UIColor clearColor];
    _scrollView.scrollsToTop = NO;
    _scrollView.delegate = self;
  }
  return _scrollView;
}

- (UIView *)scrollViewClippingView {
  if (!_scrollViewClippingView) {
    _scrollViewClippingView = [[UIView alloc] init];
    _scrollViewClippingView.backgroundColor = [UIColor clearColor];
  }
  return _scrollViewClippingView;
}

- (CGFloat)contentHeaderTopInset {
  if (_contentHeaderTopInset == NSNotFound) {
    [self cacheLayoutCalculations];
  }
  return _contentHeaderTopInset;
}

- (CGFloat)contentHeightSurplus {
  if (_contentHeightSurplus == NSNotFound) {
    [self cacheLayoutCalculations];
  }
  return _contentHeightSurplus;
}

- (CGFloat)addedContentHeight {
  if (_addedContentHeight == NSNotFound) {
    [self cacheLayoutCalculations];
  }
  return _addedContentHeight;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
  _contentHeaderTopInset = NSNotFound;
  _contentHeightSurplus = NSNotFound;
  _addedContentHeight = NSNotFound;
}

#pragma mark UIScrollViewDelegate (Private)

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
  self.scrollViewBeganDraggingFromFullscreen = self.currentlyFullscreen;
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView
                     withVelocity:(CGPoint)velocity
              targetContentOffset:(inout CGPoint *)targetContentOffset {
  BOOL scrollViewBeganDraggingFromFullscreen = self.scrollViewBeganDraggingFromFullscreen;
  self.scrollViewBeganDraggingFromFullscreen = NO;

  if (!scrollViewBeganDraggingFromFullscreen &&
      velocity.y < kDragVelocityThresholdForHidingDrawer) {
    [self hideDrawer];
    return;
  }

  if (self.scrollView.contentOffset.y < 0.f) {
    if (self.scrollView.contentOffset.y < -kVerticalDistanceThresholdForDismissal) {
      [self hideDrawer];
    } else {
      targetContentOffset->y = 0.f;
    }
    return;
  }

  CGFloat scrollToContentOffsetY =
      [self midAnimationScrollToPositionForOffset:*targetContentOffset];
  if (scrollToContentOffsetY != NSNotFound) {
    targetContentOffset->y = scrollToContentOffsetY;
  }
}

@end

#pragma mark - MDCBottomDrawerContainerViewController + Layout Calculations

@implementation MDCBottomDrawerContainerViewController (LayoutCalculations)

- (void)cacheLayoutCalculations {
  [self cacheLayoutCalculationsWithAddedContentHeight:0.f];
}

- (void)cacheLayoutCalculationsWithAddedContentHeight:(CGFloat)addedContentHeight {
  CGFloat contentHeight = self.contentViewController.preferredContentSize.height;
  CGFloat contentHeaderHeight = self.contentHeaderHeight;
  CGFloat containerHeight = self.presentingViewBounds.size.height;

  contentHeight += addedContentHeight;
  _addedContentHeight = addedContentHeight;

  CGFloat totalHeight = contentHeight + contentHeaderHeight;
  CGFloat contentHeightThresholdForScrollability =
      containerHeight * kInitialDrawerHeightFactor + contentHeaderHeight;
  BOOL contentScrollsToReveal = totalHeight > contentHeightThresholdForScrollability;

  if (_contentHeaderTopInset == NSNotFound) {
    // The content header top inset is only set once.
    if (contentScrollsToReveal) {
      _contentHeaderTopInset = containerHeight * (1.f - kInitialDrawerHeightFactor);
    } else {
      _contentHeaderTopInset = containerHeight - totalHeight;
    }
  }

  CGFloat scrollingDistance = _contentHeaderTopInset + contentHeaderHeight + contentHeight;
  _contentHeightSurplus = scrollingDistance - containerHeight;

  if (addedContentHeight < FLT_EPSILON && (_contentHeaderTopInset > _contentHeightSurplus) &&
      (_contentHeaderTopInset - _contentHeightSurplus < self.addedContentHeightThreshold)) {
    CGFloat addedContentheight = _contentHeaderTopInset - _contentHeightSurplus;
    [self cacheLayoutCalculationsWithAddedContentHeight:addedContentheight];
  }
}

- (CGFloat)transitionPercentageForContentOffset:(CGPoint)contentOffset
                                         offset:(CGFloat)offset
                                       distance:(CGFloat)distance {
  return 1.f - MAX(0.f, MIN(1.f, (self.transitionCompleteContentOffset - contentOffset.y - offset) /
                                     distance));
}

- (CGFloat)midAnimationScrollToPositionForOffset:(CGPoint)targetContentOffset {
  if (!self.contentScrollsToReveal) {
    return NSNotFound;
  }

  CGFloat headerAnimationDistance = self.headerAnimationDistance;
  CGFloat headerTransitionToTop =
      [self transitionPercentageForContentOffset:targetContentOffset
                                          offset:0
                                        distance:headerAnimationDistance];
  if (headerTransitionToTop >= FLT_EPSILON && headerTransitionToTop < 1.f) {
    CGFloat contentHeaderFullyCoversTopHeaderContentOffset = self.transitionCompleteContentOffset;
    CGFloat contentHeaderReachesTopHeaderContentOffset =
        contentHeaderFullyCoversTopHeaderContentOffset - headerAnimationDistance;
    return self.scrollViewIsDraggedToBottom ? contentHeaderReachesTopHeaderContentOffset
                                            : contentHeaderFullyCoversTopHeaderContentOffset;
  }

  return NSNotFound;
}

@end

#pragma mark - MDCBottomDrawerContainerViewController + Layout Values

@implementation MDCBottomDrawerContainerViewController (LayoutValues)

- (CGRect)presentingViewBounds {
  return CGRectStandardize(self.originalPresentingViewController.view.bounds);
}

- (BOOL)contentReachesFullscreen {
  return self.contentHeightSurplus >= self.contentHeaderTopInset;
}

- (BOOL)contentScrollsToReveal {
  return self.contentHeightSurplus > FLT_EPSILON;
}

- (CGFloat)topHeaderHeight {
  if (!self.headerViewController) {
    return 0.f;
  }
  CGFloat headerHeight = self.headerViewController.preferredContentSize.height;
  return headerHeight + MDCDeviceTopSafeAreaInset();
}

- (CGFloat)contentHeaderHeight {
  if (!self.headerViewController) {
    return 0.f;
  }
  return self.headerViewController.preferredContentSize.height;
}

- (CGFloat)transitionCompleteContentOffset {
  if (self.contentReachesFullscreen) {
    CGFloat transitionCompleteContentOffset = self.contentHeaderTopInset;
    transitionCompleteContentOffset -= self.topHeaderHeight - self.contentHeaderHeight;
    return transitionCompleteContentOffset;
  } else {
    return self.contentHeightSurplus;
  }
}

- (CGFloat)headerAnimationDistance {
  CGFloat headerAnimationDistance =
      kHeaderAnimationDistanceAddedDistanceFromTopSafeAreaInset;
  if (self.contentReachesFullscreen) {
    headerAnimationDistance += MDCDeviceTopSafeAreaInset();
  }
  return headerAnimationDistance;
}

- (CGFloat)addedContentHeightThreshold {
  // TODO: (#4900) change this to use safeAreaInsets as this is a soon to be deprecated API.
  return MDCDeviceTopSafeAreaInset();
}

@end
