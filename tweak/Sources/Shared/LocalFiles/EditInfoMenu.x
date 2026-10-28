// Edit info in a song's context menu, under either look: a row that opens an editor for its names and
// artwork, stored by the mod (LocalFiles.h).
//
// The menu is Spotify's context menu sheet, ContextMenu_InternalImpl.ContextMenuViewController, whose
// rows come from Swift item factories with no way in (Shared/Player/SpeedPitchMenu.x says more). So the
// row is the table's footer, as Speed and pitch is its header, and the sheet is the player's by
// Speed and pitch's own test. Speed and pitch takes the footer when Spotify has a header of its own in
// the table, so then the footer is left to it and Edit info is left out.
//
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "LocalFiles.h"

// The sheet's own measures, as Speed and pitch has them.
static const CGFloat kRowHeight = 56, kSideMargin = 16, kIconSide = 24;

static char kRowKey, kDecidedKey, kTrackProbeKey, kTrackProbeCountKey;

static UIFont *rowFont(void) {
    UIContentSizeCategory current = UIApplication.sharedApplication.preferredContentSizeCategory;
    if (UIContentSizeCategoryCompareToCategory(current, UIContentSizeCategoryExtraLarge) == NSOrderedDescending) current = UIContentSizeCategoryExtraLarge;
    UITraitCollection *traits = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:current];
    return [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody compatibleWithTraitCollection:traits].pointSize];
}

#pragma mark - the editor

// A form sheet over the player: the three names, the cover with a menu to change it, and a row that puts
// the file's own info back. Nothing is stored until Save, so Cancel undoes everything, a cover picked
// or removed and a restore too; a swipe down with changes asks first.

typedef NS_ENUM(NSInteger, SGCoverChange) { SGCoverKept, SGCoverPicked, SGCoverRemoved };
typedef NS_ENUM(NSInteger, SGMotionChange) { SGMotionKept, SGMotionPicked, SGMotionRemoved };

static NSArray<NSString *> *fieldKeys(void) {
    return @[@"title", @"artist", @"album"];
}

static NSArray<NSString *> *fieldLabels(void) {
    return @[@"Title", @"Artist", @"Album"];
}

static NSString *trimmed(NSString *text) {
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

@interface SGTrackEditor : UITableViewController <UITextFieldDelegate, UIAdaptivePresentationControllerDelegate,
                                                   UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
- (instancetype)initWithURI:(NSString *)uri albumURI:(NSString *)albumURI metadata:(NSDictionary *)metadata;
@end

@implementation SGTrackEditor {
    NSString *_uri;
    NSString *_albumURI;
    NSDictionary<NSString *, id> *_tags, *_shown;   // the file's own names, and the ones it goes by now
    NSArray<UITextField *> *_fields;
    NSArray<UILabel *> *_labels;
    NSArray<UIStackView *> *_stacks;
    NSArray<NSLayoutConstraint *> *_labelWidths;
    UITableViewCell *_coverCell, *_coverAlbumCell, *_motionCell, *_motionAlbumCell, *_restoreCell;
    UISwitch *_coverAlbumSwitch, *_motionAlbumSwitch;
    UIButton *_coverButton, *_motionButton;
    UIImage *_cover;
    NSURL *_motion;
    SGCoverChange _coverChange;
    SGMotionChange _motionChange;
    BOOL _hasStoredCover, _hasStoredMotion, _pickingMotion, _motionIsTemporary, _motionPreparing;
    BOOL _coverAlbumWide, _motionAlbumWide;
}

- (instancetype)initWithURI:(NSString *)uri albumURI:(NSString *)albumURI metadata:(NSDictionary *)metadata {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _uri = [uri copy];
    _albumURI = [albumURI copy];
    NSDictionary *edit = SGTrackEditFor(uri, albumURI);
    NSMutableDictionary *tags = [NSMutableDictionary dictionary];
    if (SGLocalFileIs(uri)) {
        [tags addEntriesFromDictionary:SGLocalFileTags(uri) ?: @{}];
    } else {
        for (NSString *field in @[@"title", @"artist", @"album"]) {
            NSString *key = [field isEqualToString:@"artist"] ? @"artist_name" : [field isEqualToString:@"album"] ? @"album_title" : @"title";
            if ([metadata[key] isKindOfClass:NSString.class]) tags[field] = metadata[key];
        }
    }
    _tags = tags;
    NSMutableDictionary *shown = [tags mutableCopy];
    for (NSString *field in fieldKeys()) if ([edit[field] isKindOfClass:NSString.class]) shown[field] = edit[field];
    _shown = shown;
    NSString *path = SGTrackArtworkCoverPath(edit);
    _cover = path ? [UIImage imageWithContentsOfFile:path] : nil;
    _hasStoredCover = _cover != nil;
    NSString *motionPath = SGTrackArtworkMotionPath(edit);
    _motion = motionPath ? [NSURL fileURLWithPath:motionPath] : nil;
    _hasStoredMotion = _motion && [NSFileManager.defaultManager fileExistsAtPath:_motion.path];
    NSDictionary *albumEdit = SGTrackEditFor(nil, albumURI);
    _coverAlbumWide = SGTrackArtworkCoverPath(albumEdit) != nil;
    _motionAlbumWide = SGTrackArtworkMotionPath(albumEdit) != nil;

    NSMutableArray *fields = [NSMutableArray array], *labels = [NSMutableArray array], *stacks = [NSMutableArray array], *widths = [NSMutableArray array];
    for (NSUInteger i = 0; i < fieldKeys().count; i++) {
        NSString *key = fieldKeys()[i];
        UILabel *label = [UILabel new];
        label.text = fieldLabels()[i];
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        label.adjustsFontForContentSizeCategory = YES;
        label.isAccessibilityElement = NO;   // the field reads its own label
        UITextField *field = [UITextField new];
        field.text = [edit[key] isKindOfClass:NSString.class] ? edit[key] : nil;
        field.placeholder = _tags[key] ?: fieldLabels()[i];
        field.accessibilityLabel = fieldLabels()[i];
        field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        field.adjustsFontForContentSizeCategory = YES;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
        field.returnKeyType = i + 1 < fieldKeys().count ? UIReturnKeyNext : UIReturnKeyDone;
        field.delegate = self;
        [field addTarget:self action:@selector(changed) forControlEvents:UIControlEventEditingChanged];
        [field setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, field]];
        stack.spacing = 12;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [fields addObject:field];
        [labels addObject:label];
        [stacks addObject:stack];
        [widths addObject:[label.widthAnchor constraintEqualToConstant:0]];
    }
    _fields = fields;
    _labels = labels;
    _stacks = stacks;
    _labelWidths = widths;

    self.title = @"Edit info";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _coverCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    _coverCell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIButtonConfiguration *change = [UIButtonConfiguration plainButtonConfiguration];
    change.title = @"Change";
    _coverButton = [UIButton buttonWithConfiguration:change primaryAction:nil];
    _coverButton.showsMenuAsPrimaryAction = YES;
    _coverButton.accessibilityLabel = @"Change cover";
    _coverCell.accessoryView = _coverButton;
    _coverAlbumCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    _coverAlbumCell.textLabel.text = @"Apply next cover to entire album";
    _coverAlbumSwitch = [UISwitch new];
    _coverAlbumSwitch.on = _coverAlbumWide;
    _coverAlbumSwitch.enabled = _albumURI.length > 0;
    [_coverAlbumSwitch addTarget:self action:@selector(coverAlbumChanged) forControlEvents:UIControlEventValueChanged];
    _coverAlbumCell.accessoryView = _coverAlbumSwitch;
    _coverAlbumCell.selectionStyle = UITableViewCellSelectionStyleNone;
    _motionCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    _motionCell.selectionStyle = UITableViewCellSelectionStyleNone;
    _motionButton = [UIButton buttonWithConfiguration:change primaryAction:nil];
    _motionButton.showsMenuAsPrimaryAction = YES;
    _motionButton.accessibilityLabel = @"Change animated artwork";
    _motionCell.accessoryView = _motionButton;
    _motionAlbumCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    _motionAlbumCell.textLabel.text = @"Apply next animation to entire album";
    _motionAlbumSwitch = [UISwitch new];
    _motionAlbumSwitch.on = _motionAlbumWide;
    _motionAlbumSwitch.enabled = _albumURI.length > 0;
    [_motionAlbumSwitch addTarget:self action:@selector(motionAlbumChanged) forControlEvents:UIControlEventValueChanged];
    _motionAlbumCell.accessoryView = _motionAlbumSwitch;
    _motionAlbumCell.selectionStyle = UITableViewCellSelectionStyleNone;
    _restoreCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    [self fitLabels];
    [self showCover];
    [self showMotion];
    [self changed];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(fitLabels) name:UIContentSizeCategoryDidChangeNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_motionIsTemporary) [NSFileManager.defaultManager removeItemAtURL:_motion error:nil];
}

// The names' labels share one width so the fields line up; at the accessibility sizes each label goes
// above its field instead.
- (void)fitLabels {
    BOOL stacked = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody compatibleWithTraitCollection:self.traitCollection];
    CGFloat widest = 0;
    for (NSString *text in fieldLabels()) widest = MAX(widest, ceil([text sizeWithAttributes:@{NSFontAttributeName: font}].width));
    for (NSUInteger i = 0; i < _stacks.count; i++) {
        _stacks[i].axis = stacked ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
        _stacks[i].alignment = stacked ? UIStackViewAlignmentFill : UIStackViewAlignmentFirstBaseline;
        _labelWidths[i].constant = widest;
        _labelWidths[i].active = !stacked;
    }
}

#pragma mark - state

- (NSDictionary<NSString *, NSString *> *)names {
    NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < _fields.count; i++) {
        NSString *field = fieldKeys()[i];
        NSString *effective = [self effectiveName:i];
        if (effective.length && ![effective isEqualToString:_tags[field] ?: @""]) names[field] = effective;
    }
    return names;
}

// A name the way it would be stored: an empty field is the file's own.
- (NSString *)effectiveName:(NSUInteger)i {
    NSString *typed = trimmed(_fields[i].text);
    return typed.length ? typed : _tags[fieldKeys()[i]] ?: @"";
}

- (BOOL)isDirty {
    if (_motionPreparing || _coverChange != SGCoverKept || _motionChange != SGMotionKept) return YES;
    for (NSUInteger i = 0; i < _fields.count; i++) {
        if (![[self effectiveName:i] isEqualToString:_shown[fieldKeys()[i]] ?: @""]) return YES;
    }
    return NO;
}

- (BOOL)differsFromFile {
    if (_cover || _motion) return YES;
    for (NSUInteger i = 0; i < _fields.count; i++) {
        if (![[self effectiveName:i] isEqualToString:_tags[fieldKeys()[i]] ?: @""]) return YES;
    }
    return NO;
}

- (void)changed {
    BOOL dirty = self.isDirty;
    self.navigationItem.rightBarButtonItem.enabled = dirty && !_motionPreparing;
    self.navigationItem.leftBarButtonItem.enabled = !_motionPreparing;
    _motionButton.enabled = !_motionPreparing;
    // A swipe down then asks before the changes go (presentationControllerDidAttemptToDismiss:).
    self.modalInPresentation = dirty;
    BOOL restorable = self.differsFromFile || _hasStoredCover || _hasStoredMotion;
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = @"Restore file's info";
    content.textProperties.color = restorable ? UIColor.systemRedColor : UIColor.tertiaryLabelColor;
    _restoreCell.contentConfiguration = content;
    _restoreCell.userInteractionEnabled = restorable && !_motionPreparing;
    _restoreCell.accessibilityTraits = UIAccessibilityTraitButton | (restorable ? 0 : UIAccessibilityTraitNotEnabled);
}

- (void)showCover {
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = @"Cover";
    content.secondaryText = !_cover ? @"Spotify's original" : _coverChange == SGCoverPicked ? @"New picture" : @"Custom picture";
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.image = _cover ?: [UIImage systemImageNamed:@"music.note"];
    content.imageProperties.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleTitle2];
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    content.imageProperties.maximumSize = CGSizeMake(56, 56);
    content.imageProperties.reservedLayoutSize = CGSizeMake(56, 56);
    content.imageProperties.cornerRadius = 8;
    content.imageProperties.accessibilityIgnoresInvertColors = YES;
    _coverCell.contentConfiguration = content;

    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray arrayWithArray:@[
        [UIAction actionWithTitle:@"Choose from Photos" image:[UIImage systemImageNamed:@"photo.on.rectangle"] identifier:nil handler:^(UIAction *action) {
            [weakSelf pickCoverFromFiles:NO];
        }],
        [UIAction actionWithTitle:@"Choose from Files" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *action) {
            [weakSelf pickCoverFromFiles:YES];
        }],
    ]];
    if (_cover) {
        UIAction *remove = [UIAction actionWithTitle:@"Remove cover" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *action) {
            [weakSelf useCover:nil];
        }];
        remove.attributes = UIMenuElementAttributesDestructive;
        [items addObject:remove];
    }
    _coverButton.menu = [UIMenu menuWithChildren:items];
    [_coverButton sizeToFit];
}

- (void)showMotion {
    _motionCell.textLabel.text = @"Animated artwork";
    _motionCell.detailTextLabel.text = !_motion ? @"Spotify's Canvas" :
        _motionChange == SGMotionPicked ? @"New custom video" : @"Custom video";
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray arrayWithArray:@[
        [UIAction actionWithTitle:@"Choose video or GIF from Files" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *action) {
            [weakSelf pickMotionFromFiles];
        }],
        [UIAction actionWithTitle:@"Choose video from Photos" image:[UIImage systemImageNamed:@"video"] identifier:nil handler:^(UIAction *action) {
            [weakSelf pickMotionFromPhotos];
        }],
    ]];
    if (_motion) {
        UIAction *remove = [UIAction actionWithTitle:@"Remove custom artwork" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *action) {
            [weakSelf useMotion:nil];
        }];
        remove.attributes = UIMenuElementAttributesDestructive;
        [items addObject:remove];
    }
    _motionButton.menu = [UIMenu menuWithChildren:items];
    [_motionButton sizeToFit];
}

- (void)useCover:(UIImage *)image {
    _cover = image;
    _coverChange = image ? SGCoverPicked : _hasStoredCover ? SGCoverRemoved : SGCoverKept;
    [self showCover];
    [self changed];
}

- (void)useMotion:(NSURL *)motion {
    if (!motion) {
        if (_motionIsTemporary) [NSFileManager.defaultManager removeItemAtURL:_motion error:nil];
        _motionIsTemporary = NO;
        _motion = nil;
        _motionChange = _hasStoredMotion ? SGMotionRemoved : SGMotionKept;
        [self showMotion];
        [self changed];
        return;
    }
    _motionPreparing = YES;
    [self changed];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL temporary = NO;
        NSError *error = nil;
        NSURL *prepared = SGTrackPrepareMotion(motion, &temporary, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            SGTrackEditor *editor = weakSelf;
            if (!editor) {
                if (temporary && prepared) [NSFileManager.defaultManager removeItemAtURL:prepared error:nil];
                return;
            }
            editor->_motionPreparing = NO;
            if (!prepared) {
                [editor changed];
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't use animated artwork"
                    message:error.localizedDescription ?: @"The selected video could not be prepared." preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [editor presentViewController:alert animated:YES completion:nil];
                return;
            }
            if (editor->_motionIsTemporary) [NSFileManager.defaultManager removeItemAtURL:editor->_motion error:nil];
            editor->_motion = prepared;
            editor->_motionIsTemporary = temporary;
            editor->_motionChange = SGMotionPicked;
            [editor showMotion];
            [editor changed];
        });
    });
}

- (void)coverAlbumChanged {
    _coverAlbumWide = _coverAlbumSwitch.on;
}

- (void)motionAlbumChanged {
    _motionAlbumWide = _motionAlbumSwitch.on;
}

#pragma mark - the actions

- (void)restore {
    for (NSUInteger i = 0; i < _fields.count; i++) _fields[i].text = _tags[fieldKeys()[i]];
    [self.view endEditing:YES];
    [self useCover:nil];
    [self useMotion:nil];
    _coverAlbumWide = NO;
    _motionAlbumWide = NO;
    _coverAlbumSwitch.on = NO;
    _motionAlbumSwitch.on = NO;
    [self changed];
}

- (void)save {
    [self.view endEditing:YES];
    NSError *error = nil;
    BOOL saved = SGTrackSaveEdit(_uri, _albumURI, self.names,
        _coverChange == SGCoverPicked ? _cover : nil, _coverChange != SGCoverKept, _coverAlbumWide,
        _motionChange == SGMotionPicked ? _motion : nil, _motionChange != SGMotionKept, _motionAlbumWide, &error);
    if (!saved) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't save edit"
            message:error.localizedDescription ?: @"The changes could not be saved." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)cancel {
    if (self.isDirty) [self confirmDiscard];
    else [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)confirmDiscard {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Discard changes" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Keep editing" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.leftBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentationControllerDidAttemptToDismiss:(UIPresentationController *)presentationController {
    [self confirmDiscard];
}

- (void)pickCoverFromFiles:(BOOL)files {
    [self.view endEditing:YES];
    UIViewController *picker;
    if (files) {
        // A copy, so it is the app's own to read.
        UIDocumentPickerViewController *documents = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
        documents.delegate = self;
        picker = documents;
    } else {
        // Runs out of the app's process, so no Photos permission is asked.
        UIImagePickerController *photos = [UIImagePickerController new];
        photos.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        photos.delegate = self;
        picker = photos;
    }
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)pickMotionFromFiles {
    [self.view endEditing:YES];
    _pickingMotion = YES;
    UIDocumentPickerViewController *documents = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[[UTType typeWithIdentifier:@"public.movie"], UTType.gif] asCopy:YES];
    documents.delegate = self;
    [self presentViewController:documents animated:YES completion:nil];
}

- (void)pickMotionFromPhotos {
    [self.view endEditing:YES];
    _pickingMotion = YES;
    UIImagePickerController *photos = [UIImagePickerController new];
    photos.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    photos.mediaTypes = @[@"public.movie"];
    photos.videoQuality = UIImagePickerControllerQualityTypeHigh;
    photos.delegate = self;
    [self presentViewController:photos animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    if (_pickingMotion) {
        NSURL *motion = info[UIImagePickerControllerMediaURL];
        if (motion) [self useMotion:motion];
        _pickingMotion = NO;
    } else {
        UIImage *image = info[UIImagePickerControllerOriginalImage];
        if (image) [self useCover:image];
    }
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    _pickingMotion = NO;
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (_pickingMotion) {
        _pickingMotion = NO;
        if (urls.firstObject) [self useMotion:urls.firstObject];
        return;
    }
    NSData *data = urls.firstObject ? [NSData dataWithContentsOfURL:urls.firstObject] : nil;
    UIImage *image = data ? [UIImage imageWithData:data] : nil;
    if (image) {
        [self useCover:image];
        return;
    }
    SGLog(@"local files: %@ is not an image", urls.firstObject.lastPathComponent);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Not an image" message:@"Pick a JPEG, PNG or HEIC file."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    _pickingMotion = NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    NSUInteger i = [_fields indexOfObject:field];
    if (i != NSNotFound && i + 1 < _fields.count) [_fields[i + 1] becomeFirstResponder];
    else [field resignFirstResponder];
    return NO;
}

#pragma mark - the table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return (NSInteger)_fields.count;
    if (section == 1 || section == 2) return 2;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Saved by Taurus for this song. Spotify's original file or catalog entry is not changed.";
    if (section == 1 || section == 2) return @"Each switch controls whether the next custom upload applies to this song or every song on its Spotify album.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) return indexPath.row == 0 ? _coverCell : _coverAlbumCell;
    if (indexPath.section == 2) return indexPath.row == 0 ? _motionCell : _motionAlbumCell;
    if (indexPath.section == 3) return _restoreCell;
    // One cell per name, made once: the field keeps what was typed while the table scrolls.
    UIStackView *stack = _stacks[(NSUInteger)indexPath.row];
    if (stack.superview) return (UITableViewCell *)stack.superview.superview;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    [cell.contentView addSubview:stack];
    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:margins.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
    ]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) [_fields[(NSUInteger)indexPath.row] becomeFirstResponder];
    if (indexPath.section == 3) [self restore];
}

@end

static UIViewController *topOf(UIViewController *presenter) {
    UIViewController *top = presenter;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    return top;
}

void SGTrackPresentEditor(UIViewController *presenter, NSString *uri, NSString *albumURI, NSDictionary *metadata) {
    if (!presenter || (!SGLocalFileIs(uri) && ![uri hasPrefix:@"spotify:track:"])) return;
    SGTrackEditor *editor = [[SGTrackEditor alloc] initWithURI:uri albumURI:albumURI metadata:metadata];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:editor];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    // Outside Spotify's navigation stacks a sheet takes the system's appearance, light in light mode.
    SGPresentDark(navigation);
    navigation.presentationController.delegate = editor;
    UISheetPresentationController *sheet = navigation.sheetPresentationController;
    sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
    sheet.prefersGrabberVisible = YES;
    [topOf(presenter) presentViewController:navigation animated:YES completion:nil];
}

#pragma mark - the row

@interface SGEditInfoRow : UIControl
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, copy) NSString *albumURI;
@property (nonatomic, copy) NSDictionary *metadata;
@property (nonatomic, weak) UIViewController *menu;
@end

@implementation SGEditInfoRow {
    UIImageView *_icon;
    UILabel *_title;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    UIColor *secondary = [UIColor colorWithWhite:1 alpha:UIAccessibilityDarkerSystemColorsEnabled() ? 0.80 : 0.65];
    UIImage *glyph = [UIImage systemImageNamed:@"pencil" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular]];
    // Colors drawn in, so nothing passes through the sheet's tint.
    _icon = [[UIImageView alloc] initWithImage:[glyph imageWithTintColor:secondary renderingMode:UIImageRenderingModeAlwaysOriginal]];
    _icon.contentMode = UIViewContentModeCenter;
    _title = [UILabel new];
    _title.font = rowFont();
    _title.textColor = UIColor.whiteColor;
    _title.text = @"Edit info";
    for (UIView *view in @[_icon, _title]) {
        view.userInteractionEnabled = NO;
        [self addSubview:view];
    }
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityLabel = @"Edit info";
    [self addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    [self addTarget:self action:@selector(highlight) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [self addTarget:self action:@selector(unhighlight) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    _icon.frame = CGRectMake(kSideMargin, (kRowHeight - kIconSide) / 2, kIconSide, kIconSide);
    CGFloat titleX = kSideMargin + kIconSide + kSideMargin;
    _title.frame = CGRectMake(titleX, 0, MAX(0, width - titleX - kSideMargin), kRowHeight);
}

- (void)highlight {
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
}

- (void)unhighlight {
    [UIView animateWithDuration:0.2 animations:^{ self.backgroundColor = UIColor.clearColor; }];
}

// One sheet at a time: Spotify's menu goes before the editor comes up over what presented it.
- (void)open {
    UIViewController *menu = self.menu, *host = menu.presentingViewController;
    NSString *uri = self.uri;
    NSString *albumURI = self.albumURI;
    NSDictionary *metadata = self.metadata;
    if (!host) {
        SGTrackPresentEditor(menu, uri, albumURI, metadata);
        return;
    }
    [menu dismissViewControllerAnimated:YES completion:^{ SGTrackPresentEditor(host, uri, albumURI, metadata); }];
}

@end

#pragma mark - the menu

static UITableView *findTable(UIView *root, int depth) {
    if ([root isKindOfClass:UITableView.class]) return (UITableView *)root;
    if (depth > 5) return nil;
    for (UIView *child in root.subviews) {
        UITableView *table = findTable(child, depth + 1);
        if (table) return table;
    }
    return nil;
}

static BOOL freeSlot(UIView *view) {
    return !view || view.bounds.size.height < 1;
}

static void decide(UIViewController *menu, BOOL offered) {
    objc_setAssociatedObject(menu, &kDecidedKey, @(offered), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL isTrackURI(id value) {
    return [value isKindOfClass:NSString.class]
        && ([value hasPrefix:@"spotify:track:"] || SGLocalFileIs(value));
}

static void inspectMenuValue(id value, NSUInteger depth, NSHashTable *visited,
                             NSMutableSet<NSString *> *trackURIs, NSMutableSet<NSString *> *albumURIs,
                             NSMutableDictionary<NSString *, NSDictionary *> *metadataByURI) {
    if (!value || depth > 7) return;
    if ([value isKindOfClass:NSString.class]) {
        if (isTrackURI(value)) [trackURIs addObject:value];
        else if ([value hasPrefix:@"spotify:album:"]) [albumURIs addObject:value];
        return;
    }
    if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSDate.class] || [visited containsObject:value]) return;
    [visited addObject:value];

    NSString *className = NSStringFromClass([value class]);
    if (depth && [value isKindOfClass:UIViewController.class]
        && ![className containsString:@"ContextMenu"] && ![className containsString:@"HostingController"]) return;
    if ([className containsString:@"SPTPlayerTrack"] && [value respondsToSelector:@selector(URI)]) {
        id (*objectGetter)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        NSString *uri = SGURIString(objectGetter(value, @selector(URI)));
        if (isTrackURI(uri)) {
            [trackURIs addObject:uri];
            NSDictionary *metadata = [value respondsToSelector:@selector(metadata)] ? objectGetter(value, @selector(metadata)) : nil;
            metadata = SGTrackOriginalMetadata((SPTPlayerTrack *)value) ?: metadata;
            if ([metadata isKindOfClass:NSDictionary.class]) {
                metadataByURI[uri] = metadata;
                id albumURI = metadata[@"album_uri"];
                if ([albumURI isKindOfClass:NSString.class]) [albumURIs addObject:albumURI];
            }
        }
        return;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        NSString *dictionaryTrackURI = nil;
        for (id childKey in dictionary) {
            if (![childKey isKindOfClass:NSString.class]) continue;
            NSString *key = [childKey lowercaseString];
            id child = dictionary[childKey];
            if (([key isEqualToString:@"uri"] || ([key containsString:@"track"] && [key containsString:@"uri"]))
                && isTrackURI(child)) {
                dictionaryTrackURI = child;
                break;
            }
        }
        if (dictionaryTrackURI) {
            NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
            NSDictionary *nested = [dictionary[@"metadata"] isKindOfClass:NSDictionary.class] ? dictionary[@"metadata"] : dictionary;
            for (NSString *field in @[@"title", @"artist_name", @"album_title", @"album_uri"]) {
                id child = nested[field];
                if ([child isKindOfClass:NSString.class]) metadata[field] = child;
            }
            if (metadata.count) metadataByURI[dictionaryTrackURI] = metadata;
        }
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id childKey, id child, BOOL *stop) {
            if ([childKey isKindOfClass:NSString.class] && [childKey containsString:@"album_uri"]
                && [child isKindOfClass:NSString.class]) [albumURIs addObject:child];
            inspectMenuValue(child, depth + 1, visited, trackURIs, albumURIs, metadataByURI);
        }];
        return;
    }
    if ([value isKindOfClass:NSArray.class] || [value isKindOfClass:NSSet.class]) {
        for (id child in value) inspectMenuValue(child, depth + 1, visited, trackURIs, albumURIs, metadataByURI);
        return;
    }
    if ([value isKindOfClass:UIView.class]) return;

    for (Class type = [value class]; type && type != NSObject.class; type = class_getSuperclass(type)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(type, &count);
        for (unsigned int index = 0; index < count; index++) {
            Ivar ivar = ivars[index];
            const char *encoding = ivar_getTypeEncoding(ivar);
            if (encoding && encoding[0] == '@') {
                inspectMenuValue(object_getIvar(value, ivar), depth + 1, visited, trackURIs, albumURIs, metadataByURI);
            }
        }
        free(ivars);
    }
}

static NSDictionary *menuTrack(UIViewController *menu) {
    NSMutableSet<NSString *> *trackURIs = [NSMutableSet set];
    NSMutableSet<NSString *> *albumURIs = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSDictionary *> *metadataByURI = [NSMutableDictionary dictionary];
    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    inspectMenuValue(menu, 0, visited, trackURIs, albumURIs, metadataByURI);
    if (trackURIs.count != 1) return nil;
    NSString *uri = trackURIs.anyObject;
    NSDictionary *metadata = metadataByURI[uri];
    if (!metadata && [SGURIString(SGPlayerState().track.URI) isEqualToString:uri]) {
        NSDictionary *playingMetadata = SGPlayerState().track.metadata;
        metadata = SGTrackOriginalMetadata(SGPlayerState().track) ?: playingMetadata;
        id playingAlbumURI = metadata[@"album_uri"];
        if ([playingAlbumURI isKindOfClass:NSString.class]) [albumURIs addObject:playingAlbumURI];
    }
    NSString *albumURI = [metadata[@"album_uri"] isKindOfClass:NSString.class] ? metadata[@"album_uri"]
        : albumURIs.count == 1 ? albumURIs.anyObject : nil;
    return @{@"uri": uri, @"albumURI": albumURI ?: NSNull.null, @"metadata": metadata ?: NSNull.null};
}

static void install(UIViewController *menu) {
    UIView *root = menu.viewIfLoaded;
    if (!root || [objc_getAssociatedObject(menu, &kDecidedKey) isEqual:@NO]) return;
    UITableView *table = findTable(root, 0);
    CGFloat width = table.bounds.size.width;
    if (width <= 0) return;
    SGEditInfoRow *row = objc_getAssociatedObject(menu, &kRowKey);
    if (!row) {
        NSNumber *lastProbe = objc_getAssociatedObject(menu, &kTrackProbeKey);
        if (lastProbe && NSDate.date.timeIntervalSince1970 - lastProbe.doubleValue < 0.25) return;
        objc_setAssociatedObject(menu, &kTrackProbeKey, @(NSDate.date.timeIntervalSince1970), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSDictionary *track = menuTrack(menu);
        if (!track) {
            NSUInteger probes = [objc_getAssociatedObject(menu, &kTrackProbeCountKey) unsignedIntegerValue] + 1;
            objc_setAssociatedObject(menu, &kTrackProbeCountKey, @(probes), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (probes >= 12) {
                SGLog(@"track info: no unique song found in %@; Edit info left out", NSStringFromClass(menu.class));
                decide(menu, NO);
            }
            return;
        }
        NSString *uri = track[@"uri"];
        NSString *albumURI = track[@"albumURI"] == NSNull.null ? nil : track[@"albumURI"];
        NSDictionary *metadata = track[@"metadata"] == NSNull.null ? nil : track[@"metadata"];
        // A header of Spotify's own sends Speed and pitch to the footer.
        UIView *header = table.tableHeaderView;
        BOOL headerOurs = freeSlot(header) || [NSStringFromClass(header.class) hasPrefix:@"SG"];
        if (!headerOurs || !freeSlot(table.tableFooterView)) {
            SGLog(@"local files: the menu's table has %@ and %@, Edit info left out",
                  header ? NSStringFromClass(header.class) : @"no header", table.tableFooterView ? NSStringFromClass(table.tableFooterView.class) : @"no footer");
            decide(menu, NO);
            return;
        }
        decide(menu, YES);
        row = [[SGEditInfoRow alloc] initWithFrame:CGRectMake(0, 0, width, kRowHeight)];
        row.uri = uri;
        row.albumURI = albumURI;
        row.metadata = metadata;
        row.menu = menu;
        objc_setAssociatedObject(menu, &kRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        table.tableFooterView = row;
        [table invalidateIntrinsicContentSize];
        SGLog(@"track info: Edit info offered for %@", uri);
        return;
    }
    // Spotify replaced the footer, or the table changed width: put it back at the table's width.
    if (table.tableFooterView != row || fabs(row.frame.size.width - width) > 0.5) {
        row.frame = CGRectMake(0, row.frame.origin.y, width, kRowHeight);
        table.tableFooterView = row;
        [table invalidateIntrinsicContentSize];
    }
}

%hook _TtC24ContextMenu_InternalImpl25ContextMenuViewController
- (void)viewDidLayoutSubviews {
    %orig;
    install((UIViewController *)self);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC24ContextMenu_InternalImpl25ContextMenuViewController"]);
}
