//
//  ListTableViewController.h
//  tritonplayer-sample-app
//
//  Copyright (c) 2015 Triton Digital. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "ArrayDataSource.h"

@interface ListTableViewController : UITableViewController

@property (nonatomic, copy) ArrayDataSource *arrayDataSource;

@end
