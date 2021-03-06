//
//  FLPasteView.h
//  Flick
//
//  Created by Matt Nichols on 11/18/13.
//  Copyright (c) 2013 Matt Nichols. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "FLEntity.h"

#define AUTO_SWIPE_DISTANCE 50.0f

@protocol FLPasteViewDelegate <NSObject>

- (void)shouldStorePaste:(FLEntity *)pasteEntity;
- (void)didDismissPaste:(FLEntity *)pasteEntity;
- (void)pasteViewActive;
- (void)pasteViewReset;
- (void)pasteViewMoved:(CGFloat)yOffset;

@end

@interface FLPasteView : UIView

@property (nonatomic, weak) id<FLPasteViewDelegate> delegate;
@property (nonatomic) FLEntity *entity;
@property (nonatomic, getter = isDisplayed) BOOL displayed;

- (void)fadeIn:(CGFloat)duration;
- (void)animateExitWithCompletion:(void (^)())completion;

@end
