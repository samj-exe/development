#import <UIKit/UIKit.h>
#import "LocalFiles.h"

@interface SGLocalFileEditCanvas : UITableViewController <UITextFieldDelegate>
@end

@implementation SGLocalFileEditCanvas {
    NSString *_uri;
    NSDictionary *_tags;
    NSDictionary *_info;
    NSArray<UITextField *> *_fields;
}

- (instancetype)initWithURI:(NSString *)uri {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _uri = [uri copy];
    _tags = SGLocalFileTags(uri) ?: @{};
    _info = SGLocalFileInfo(uri) ?: @{};
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Edit info";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)];

    NSArray<NSString *> *keys = @[@"title", @"artist", @"album"];
    NSArray<NSString *> *labels = @[@"Title", @"Artist", @"Album"];
    NSMutableArray<UITextField *> *fields = [NSMutableArray array];
    for (NSUInteger i = 0; i < keys.count; i++) {
        UITextField *field = [UITextField new];
        field.delegate = self;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.text = _info[keys[i]] ?: _tags[keys[i]] ?: @"";
        field.placeholder = labels[i];
        [fields addObject:field];
    }
    _fields = fields;
}

- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)save {
    NSDictionary *names = @{ @"title": _fields[0].text ?: @"", @"artist": _fields[1].text ?: @"", @"album": _fields[2].text ?: @"" };
    NSError *error = nil;
    if (!SGLocalFileSaveEdit(_uri, names, nil, YES, &error)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Could not save" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 1; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return _fields.count; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UILabel *label = [UILabel new];
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    label.textColor = UIColor.secondaryLabelColor;
    NSArray<NSString *> *labels = @[@"Title", @"Artist", @"Album"];
    label.text = labels[indexPath.row];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    UITextField *field = _fields[indexPath.row];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:label];
    [cell.contentView addSubview:field];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [label.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [label.widthAnchor constraintEqualToConstant:64],
        [field.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:12],
        [field.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [field.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
        [field.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor]
    ]];
    return cell;
}

- (BOOL)textFieldShouldReturn:(UITextField *)field { [field resignFirstResponder]; return YES; }
@end

UIViewController *SGLocalFileEditCanvasPage(NSString *uri) {
    SGLocalFileEditCanvas *canvas = [[SGLocalFileEditCanvas alloc] initWithURI:uri];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:canvas];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    return nav;
}
