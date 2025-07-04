/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "IGListAdapter+UICollectionView.h"

#if !__has_include(<IGListDiffKit/IGListDiffKit.h>)
#import "IGListAssert.h"
#else
#import <IGListDiffKit/IGListAssert.h>
#endif
#import "IGListAdapterInternal.h"
#import "IGListSectionController.h"
#import "IGListSectionControllerInternal.h"
#import "IGListUpdatingDelegate.h"

#import "IGListAdapterInternal.h"

@implementation IGListAdapter (UICollectionView)

#pragma mark - UICollectionViewDataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    _assertNotInMiddleOfObjectUpdate(self.isInObjectUpdateTransaction);
    return self.sectionMap.objects.count;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    _assertNotInMiddleOfObjectUpdate(self.isInObjectUpdateTransaction);

    IGListSectionController * sectionController = [self sectionControllerForSection:section];
    IGAssert(sectionController != nil, @"Nil section controller for section %li for item %@. Check your -diffIdentifier and -isEqual: implementations.",
             (long)section, [self.sectionMap objectForSection:section]);
    const NSInteger numberOfItems = [sectionController numberOfItems];
    IGAssert(numberOfItems >= 0, @"Cannot return negative number of items %li for section controller %@.", (long)numberOfItems, sectionController);
    return numberOfItems;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    id<IGListAdapterPerformanceDelegate> performanceDelegate = self.performanceDelegate;
    [performanceDelegate listAdapterWillCallDequeueCell:self];

    IGListSectionController *sectionController = [self sectionControllerForSection:indexPath.section];
    IGAssert(sectionController != nil, @"Section controller nil for section %d", (int)indexPath.section);
    IGAssert(sectionController.collectionContext != nil, @"sectionController.collectionContext nil for section %d", (int)indexPath.section);

#if IG_ASSERTIONS_ENABLED
    if (!_dequeuedCells) {
        _dequeuedCells = [NSMutableSet new];
    }
#endif

    // flag that a cell is being dequeued in case it tries to access a cell in the process
    _isDequeuingCell = YES;
    UICollectionViewCell *cell = [sectionController cellForItemAtIndex:indexPath.item];
    _isDequeuingCell = NO;

    IGAssert(cell != nil, @"Returned a nil cell at indexPath <%@> from section controller: <%@>, dataSource: <%@>", indexPath, sectionController, self.dataSource.class);
    if (cell) {
        IGAssert(cell.reuseIdentifier != nil, @"Returned a cell without a reuseIdentifier at indexPath <%@> from section controller: <%@>", indexPath, sectionController);

        if (_dequeuedCells) {
            // This will cause a crash in iOS 18
            IGAssert([_dequeuedCells containsObject:cell], @"Returned a cell (%@) that was not dequeued at indexPath %@ from section controller %@", NSStringFromClass([cell class]), indexPath, sectionController);
        }
    }

    if (cell == nil) {
        [self.updater willCrashWithCollectionView:collectionView sectionControllerClass:sectionController.class];
    }

    [_dequeuedCells removeAllObjects];

    // associate the section controller with the cell so that we know which section controller is using it
    [self mapView:cell toSectionController:sectionController];

    [performanceDelegate listAdapter:self didCallDequeueCell:cell onSectionController:sectionController atIndex:indexPath.item];
    return cell;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    IGListSectionController *sectionController = [self sectionControllerForSection:indexPath.section];
    id <IGListSupplementaryViewSource> supplementarySource = [sectionController supplementaryViewSource];

#if IG_ASSERTIONS_ENABLED
    if (!_dequeuedSupplementaryViews) {
        _dequeuedSupplementaryViews = [NSMutableSet new];
    }
#endif

    // flag that a supplementary view is being dequeued in case it tries to access a supplementary view in the process
    _isDequeuingSupplementaryView = YES;
    UICollectionReusableView *view = [supplementarySource viewForSupplementaryElementOfKind:kind atIndex:indexPath.item];
    _isDequeuingSupplementaryView = NO;

    IGAssert(view != nil, @"Returned a nil supplementary view at indexPath <%@> from section controller: <%@>, supplementary source: <%@>", indexPath, sectionController, supplementarySource);

    if (view && _dequeuedSupplementaryViews) {
        // This will cause a crash in iOS 18
        IGAssert([_dequeuedSupplementaryViews containsObject:view], @"Returned a supplementary-view (%@) that was not dequeued at indexPath %@ from supplementary source %@", NSStringFromClass([view class]), indexPath, supplementarySource);
    }
    [_dequeuedSupplementaryViews removeAllObjects];

    // associate the section controller with the cell so that we know which section controller is using it
    [self mapView:view toSectionController:sectionController];

    return view;
}

- (BOOL)collectionView:(UICollectionView *)collectionView canMoveItemAtIndexPath:(NSIndexPath *)indexPath {
    const NSInteger sectionIndex = indexPath.section;
    const NSInteger itemIndex = indexPath.item;

    IGListSectionController *sectionController = [self sectionControllerForSection:sectionIndex];
    return [sectionController canMoveItemAtIndex:itemIndex];
}

- (void)collectionView:(UICollectionView *)collectionView
   moveItemAtIndexPath:(NSIndexPath *)sourceIndexPath
           toIndexPath:(NSIndexPath *)destinationIndexPath {

    const NSInteger sourceSectionIndex = sourceIndexPath.section;
    const NSInteger destinationSectionIndex = destinationIndexPath.section;
    const NSInteger sourceItemIndex = sourceIndexPath.item;
    const NSInteger destinationItemIndex = destinationIndexPath.item;

    IGListSectionController *sourceSectionController = [self sectionControllerForSection:sourceSectionIndex];
    IGListSectionController *destinationSectionController = [self sectionControllerForSection:destinationSectionIndex];

    // this is a move within a section
    if (sourceSectionController == destinationSectionController) {

        if ([sourceSectionController canMoveItemAtIndex:sourceItemIndex toIndex:destinationItemIndex]) {
            [self moveInSectionControllerInteractive:sourceSectionController
                                           fromIndex:sourceItemIndex
                                             toIndex:destinationItemIndex];
        } else {
            // otherwise this is a move of an _item_ from one section to another section
            // we need to revert the change as it's too late to cancel
            [self revertInvalidInteractiveMoveFromIndexPath:sourceIndexPath toIndexPath:destinationIndexPath];
        }
        return;
    }

    // this is a reordering of sections themselves
    if ([sourceSectionController numberOfItems] == 1 && [destinationSectionController numberOfItems] == 1) {

        // perform view changes in the collection view
        [self moveSectionControllerInteractive:sourceSectionController
                                     fromIndex:sourceSectionIndex
                                       toIndex:destinationSectionIndex];
        return;
    }

    // otherwise this is a move of an _item_ from one section to another section
    // this is not currently supported, so we need to revert the change as it's too late to cancel
    [self revertInvalidInteractiveMoveFromIndexPath:sourceIndexPath toIndexPath:destinationIndexPath];
}

#pragma mark - UICollectionViewDelegate

- (BOOL)collectionView:(UICollectionView *)collectionView shouldSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    IGListSectionController * sectionController = [self sectionControllerForSection:indexPath.section];
    return [sectionController shouldSelectItemAtIndex:indexPath.item];
}

- (BOOL)collectionView:(UICollectionView *)collectionView shouldDeselectItemAtIndexPath:(NSIndexPath *)indexPath {
    IGListSectionController * sectionController = [self sectionControllerForSection:indexPath.section];
    return [sectionController shouldDeselectItemAtIndex:indexPath.item];
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView didSelectItemAtIndexPath:indexPath];
    }

    IGListSectionController * sectionController = [self sectionControllerForSection:indexPath.section];
    [sectionController didSelectItemAtIndex:indexPath.item];
}

- (void)collectionView:(UICollectionView *)collectionView didDeselectItemAtIndexPath:(NSIndexPath *)indexPath {
    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:didDeselectItemAtIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView didDeselectItemAtIndexPath:indexPath];
    }

    IGListSectionController * sectionController = [self sectionControllerForSection:indexPath.section];
    [sectionController didDeselectItemAtIndex:indexPath.item];
}

- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    id<IGListAdapterPerformanceDelegate> performanceDelegate = self.performanceDelegate;
    [performanceDelegate listAdapterWillCallDisplayCell:self];

    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:willDisplayCell:forItemAtIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView willDisplayCell:cell forItemAtIndexPath:indexPath];
    }

    IGListSectionController *sectionController = [self sectionControllerForView:cell];
    // if the section controller relationship was destroyed, reconnect it
    // this happens with iOS 10 UICollectionView display range changes
    if (sectionController == nil) {
        sectionController = [self sectionControllerForSection:indexPath.section];
        [self mapView:cell toSectionController:sectionController];
    }

    id object = [self.sectionMap objectForSection:indexPath.section];
    [self.displayHandler willDisplayCell:cell forListAdapter:self sectionController:sectionController object:object indexPath:indexPath];

    _isSendingWorkingRangeDisplayUpdates = YES;
    [self.workingRangeHandler willDisplayItemAtIndexPath:indexPath forListAdapter:self];
    _isSendingWorkingRangeDisplayUpdates = NO;

    [performanceDelegate listAdapter:self didCallDisplayCell:cell onSectionController:sectionController atIndex:indexPath.item];
}

- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    id<IGListAdapterPerformanceDelegate> performanceDelegate = self.performanceDelegate;
    [performanceDelegate listAdapterWillCallEndDisplayCell:self];

    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:didEndDisplayingCell:forItemAtIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView didEndDisplayingCell:cell forItemAtIndexPath:indexPath];
    }

    IGListSectionController *const sectionController = [self sectionControllerForView:cell];
    [self.displayHandler didEndDisplayingCell:cell forListAdapter:self sectionController:sectionController indexPath:indexPath];
    [self.workingRangeHandler didEndDisplayingItemAtIndexPath:indexPath forListAdapter:self];

    // break the association between the cell and the section controller
    [self removeMapForView:cell];

    [performanceDelegate listAdapter:self didCallEndDisplayCell:cell onSectionController:sectionController atIndex:indexPath.item];
}

- (void)collectionView:(UICollectionView *)collectionView willDisplaySupplementaryView:(UICollectionReusableView *)view forElementKind:(NSString *)elementKind atIndexPath:(NSIndexPath *)indexPath {
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:willDisplaySupplementaryView:forElementKind:atIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView willDisplaySupplementaryView:view forElementKind:elementKind atIndexPath:indexPath];
    }

    IGListSectionController *sectionController = [self sectionControllerForView:view];
    // if the section controller relationship was destroyed, reconnect it
    // this happens with iOS 10 UICollectionView display range changes
    if (sectionController == nil) {
        sectionController = [self sectionControllerForSection:indexPath.section];
        [self mapView:view toSectionController:sectionController];
    }

    id object = [self.sectionMap objectForSection:indexPath.section];
    [self.displayHandler willDisplaySupplementaryView:view forListAdapter:self sectionController:sectionController object:object indexPath:indexPath];
}

- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingSupplementaryView:(UICollectionReusableView *)view forElementOfKind:(NSString *)elementKind atIndexPath:(NSIndexPath *)indexPath {
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:didEndDisplayingSupplementaryView:forElementOfKind:atIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView didEndDisplayingSupplementaryView:view forElementOfKind:elementKind atIndexPath:indexPath];
    }

    IGListSectionController *sectionController = [self sectionControllerForView:view];
    [self.displayHandler didEndDisplayingSupplementaryView:view forListAdapter:self sectionController:sectionController indexPath:indexPath];

    [self removeMapForView:view];
}

- (BOOL)collectionView:(UICollectionView *)collectionView shouldBeginMultipleSelectionInteractionAtIndexPath:(NSIndexPath *)indexPath {
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;    
    if (@available(iOS 13.0, *)) {
        if ([collectionViewDelegate respondsToSelector:@selector(collectionView:shouldBeginMultipleSelectionInteractionAtIndexPath:)]) {
            return [collectionViewDelegate collectionView:collectionView shouldBeginMultipleSelectionInteractionAtIndexPath:indexPath];
        }
    }
    return NO;
}

- (void)collectionView:(UICollectionView *)collectionView didBeginMultipleSelectionInteractionAtIndexPath:(NSIndexPath *)indexPath {
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if (@available(iOS 13.0, *)) {
        if ([collectionViewDelegate respondsToSelector:@selector(collectionView:didBeginMultipleSelectionInteractionAtIndexPath:)]) {
            [collectionViewDelegate collectionView:collectionView didBeginMultipleSelectionInteractionAtIndexPath:indexPath];
        }
    }
}

- (void)collectionViewDidEndMultipleSelectionInteraction:(UICollectionView *)collectionView {
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if (@available(iOS 13.0, *)) {
        if ([collectionViewDelegate respondsToSelector:@selector(collectionViewDidEndMultipleSelectionInteraction:)]) {
            [collectionViewDelegate collectionViewDidEndMultipleSelectionInteraction: collectionView];
        }
    }
}

- (void)collectionView:(UICollectionView *)collectionView didHighlightItemAtIndexPath:(NSIndexPath *)indexPath {
    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:didHighlightItemAtIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView didHighlightItemAtIndexPath:indexPath];
    }

    IGListSectionController * sectionController = [self sectionControllerForSection:indexPath.section];
    [sectionController didHighlightItemAtIndex:indexPath.item];
}

- (void)collectionView:(UICollectionView *)collectionView didUnhighlightItemAtIndexPath:(NSIndexPath *)indexPath {
    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:didUnhighlightItemAtIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView didUnhighlightItemAtIndexPath:indexPath];
    }

    IGListSectionController * sectionController = [self sectionControllerForSection:indexPath.section];
    [sectionController didUnhighlightItemAtIndex:indexPath.item];
}

- (NSIndexPath *)indexPathForPreferredFocusedViewInCollectionView:(UICollectionView *)collectionView {
    // In case the delegate responds, it should take priority
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(indexPathForPreferredFocusedViewInCollectionView:)]) {
        return [collectionViewDelegate indexPathForPreferredFocusedViewInCollectionView:collectionView];
    }

    if (IGListExperimentEnabled(self.experiments, IGListExperimentFixPreferredFocusedView)) {
        // The default implementation of `-[UICollectionView preferredFocusedView]` can create/dequeue off-screen
        // cells, which causes perf issues and bugs.
        return [[collectionView indexPathsForVisibleItems] firstObject];
    }

    return nil;
}

#pragma mark - UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    IGWarn(![self.collectionViewDelegate respondsToSelector:_cmd], @"IGListAdapter is consuming method also implemented by the collectionViewDelegate: %@", NSStringFromSelector(_cmd));

    CGSize size = [self sizeForItemAtIndexPath:indexPath];
    IGAssert(!isnan(size.height), @"IGListAdapter returned NaN height = %f for item at indexPath <%@>", size.height, indexPath);
    IGAssert(!isnan(size.width), @"IGListAdapter returned NaN width = %f for item at indexPath <%@>", size.width, indexPath);

    return size;
}

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout insetForSectionAtIndex:(NSInteger)section {
    IGWarn(![self.collectionViewDelegate respondsToSelector:_cmd], @"IGListAdapter is consuming method also implemented by the collectionViewDelegate: %@", NSStringFromSelector(_cmd));
    return [[self sectionControllerForSection:section] inset];
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout minimumLineSpacingForSectionAtIndex:(NSInteger)section {
    IGWarn(![self.collectionViewDelegate respondsToSelector:_cmd], @"IGListAdapter is consuming method also implemented by the collectionViewDelegate: %@", NSStringFromSelector(_cmd));
    return [[self sectionControllerForSection:section] minimumLineSpacing];
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout minimumInteritemSpacingForSectionAtIndex:(NSInteger)section {
    IGWarn(![self.collectionViewDelegate respondsToSelector:_cmd], @"IGListAdapter is consuming method also implemented by the collectionViewDelegate: %@", NSStringFromSelector(_cmd));
    return [[self sectionControllerForSection:section] minimumInteritemSpacing];
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout referenceSizeForHeaderInSection:(NSInteger)section {
    IGWarn(![self.collectionViewDelegate respondsToSelector:_cmd], @"IGListAdapter is consuming method also implemented by the collectionViewDelegate: %@", NSStringFromSelector(_cmd));
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:0 inSection:section];
    return [self sizeForSupplementaryViewOfKind:UICollectionElementKindSectionHeader atIndexPath:indexPath];
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout*)collectionViewLayout referenceSizeForFooterInSection:(NSInteger)section {
    IGWarn(![self.collectionViewDelegate respondsToSelector:_cmd], @"IGListAdapter is consuming method also implemented by the collectionViewDelegate: %@", NSStringFromSelector(_cmd));
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:0 inSection:section];
    return [self sizeForSupplementaryViewOfKind:UICollectionElementKindSectionFooter atIndexPath:indexPath];
}

#pragma mark - IGListCollectionViewDelegateLayout

- (UICollectionViewLayoutAttributes *)collectionView:(UICollectionView *)collectionView
                                              layout:(UICollectionViewLayout*)collectionViewLayout
                   customizedInitialLayoutAttributes:(UICollectionViewLayoutAttributes *)attributes
                                         atIndexPath:(NSIndexPath *)indexPath {
    IGListSectionController *sectionController = [self sectionControllerForSection:indexPath.section];
    if (sectionController.transitionDelegate) {
        return [sectionController.transitionDelegate listAdapter:self
                               customizedInitialLayoutAttributes:attributes
                                               sectionController:sectionController
                                                         atIndex:indexPath.item];
    }
    return attributes;
}

- (UICollectionViewLayoutAttributes *)collectionView:(UICollectionView *)collectionView
                                              layout:(UICollectionViewLayout*)collectionViewLayout
                     customizedFinalLayoutAttributes:(UICollectionViewLayoutAttributes *)attributes
                                         atIndexPath:(NSIndexPath *)indexPath {
    IGListSectionController *sectionController = [self sectionControllerForSection:indexPath.section];
    if (sectionController.transitionDelegate) {
        return [sectionController.transitionDelegate listAdapter:self
                                 customizedFinalLayoutAttributes:attributes
                                               sectionController:sectionController
                                                         atIndex:indexPath.item];
    }
    return attributes;
}

#pragma mark - Assert helpers

static void _assertNotInMiddleOfObjectUpdate(BOOL isInObjectUpdateTransaction) {
    IGAssert(isInObjectUpdateTransaction == NO, @"The UICollectionView is attempting to update its data while the IGListAdapter is in a middle of updating the object list. This will cause inconsistencies and potentially crashes (which are hard to debug). The most common cause is a section controller tries to access/modify the UICollectionView in -didUpdateToObject.");
}

@end
