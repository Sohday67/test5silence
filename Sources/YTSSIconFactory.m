#import "YTSSIconFactory.h"

@implementation YTSSIconFactory

+ (UIImage *)overlayIconEnabled:(BOOL)enabled jumpMode:(BOOL)jumpMode {
    CGSize size = CGSizeMake(28.0, 28.0);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = UIScreen.mainScreen.scale;

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef ctx = context.CGContext;
        UIColor *ink = UIColor.whiteColor;
        [ink setStroke];
        [ink setFill];

        CGFloat midY = 14.0;
        CGFloat lineWidth = 2.0;
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetLineWidth(ctx, lineWidth);

        NSArray<NSNumber *> *bars = jumpMode ? @[@6, @14, @8, @18, @10] : @[@5, @11, @17, @11, @5];
        CGFloat x = 5.5;
        for (NSNumber *heightValue in bars) {
            CGFloat h = heightValue.doubleValue;
            CGContextMoveToPoint(ctx, x, midY - h / 2.0);
            CGContextAddLineToPoint(ctx, x, midY + h / 2.0);
            CGContextStrokePath(ctx);
            x += 4.2;
        }

        if (jumpMode) {
            UIBezierPath *arrow = [UIBezierPath bezierPath];
            [arrow moveToPoint:CGPointMake(19.0, 9.0)];
            [arrow addLineToPoint:CGPointMake(24.0, 14.0)];
            [arrow addLineToPoint:CGPointMake(19.0, 19.0)];
            arrow.lineWidth = lineWidth;
            arrow.lineCapStyle = kCGLineCapRound;
            arrow.lineJoinStyle = kCGLineJoinRound;
            [arrow stroke];
        }

        if (!enabled) {
            CGContextSetLineWidth(ctx, 2.6);
            CGContextMoveToPoint(ctx, 5.0, 23.0);
            CGContextAddLineToPoint(ctx, 23.0, 5.0);
            CGContextStrokePath(ctx);
        }
    }];

    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

@end
