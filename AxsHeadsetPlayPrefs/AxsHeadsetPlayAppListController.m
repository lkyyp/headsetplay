#import "AxsHeadsetPlayAppListController.h"
#import "AxsHeadsetPlayCatalog.h"
#import "AxsHeadsetPlayPreferences.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>

@implementation AxsHeadsetPlayAppListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"选择要自动打开的音乐 App"
                                                           target:nil
                                                              set:nil
                                                              get:nil
                                                           detail:nil
                                                             cell:PSGroupCell
                                                             edit:nil];
        [items addObject:group];
        for (NSUInteger index = 0; index < kAxsHeadsetPlayCatalogCount; index++) {
            const AxsHeadsetPlayCatalogEntry *entry = &kAxsHeadsetPlayCatalog[index];
            PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:@(entry->title)
                                                               target:self
                                                                  set:nil
                                                                  get:nil
                                                               detail:nil
                                                                 cell:PSListItemCell
                                                                 edit:nil];
            [item setProperty:@(entry->bundleID) forKey:@"axs_headsetplay_bundleID"];
            [item setProperty:@(entry->bundleID) forKey:@"id"];
            [items addObject:item];
        }
        _specifiers = items;
    }
    return _specifiers;
}

- (NSString *)axs_headsetplay_selectedBundleID {
    id value = axs_headsetplay_readPreferences()[@"musicApp"];
    return [value isKindOfClass:[NSString class]] && [value length] > 0 ? value : @"com.netease.cloudmusic";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    NSString *bundleID = nil;
    if ([cell isKindOfClass:[PSTableCell class]]) {
        bundleID = [((PSTableCell *)cell).specifier propertyForKey:@"axs_headsetplay_bundleID"];
    }
    cell.accessoryType = [bundleID isEqualToString:[self axs_headsetplay_selectedBundleID]]
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSString *bundleID = nil;
    if ([cell isKindOfClass:[PSTableCell class]]) {
        bundleID = [((PSTableCell *)cell).specifier propertyForKey:@"axs_headsetplay_bundleID"];
    }
    if (bundleID.length == 0) {
        return;
    }
    NSError *error = nil;
    if (!axs_headsetplay_writePreference(@"musicApp", bundleID, &error)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"设置未保存"
            message:error.localizedDescription ?: @"请检查配置文件路径和写入权限。"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self reloadSpecifiers];
    id parent = [self valueForKey:@"parentController"];
    if ([parent respondsToSelector:@selector(reloadSpecifiers)]) {
        [parent reloadSpecifiers];
    }
}

@end

