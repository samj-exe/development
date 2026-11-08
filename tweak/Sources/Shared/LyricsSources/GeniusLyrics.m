#import "Core/SGCore.h"
#import "LyricsSources.h"
#import "Shared/Lyrics/Lyrics.h"

static NSString *plainText(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSData *data = [((NSString *)value) dataUsingEncoding:NSUTF8StringEncoding];
    NSAttributedString *plain = [[NSAttributedString alloc] initWithData:data
        options:@{NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType}
        documentAttributes:nil error:nil];
    return plain.string;
}

static NSString *matchFold(NSString *text) {
    NSString *folded = [text stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil].lowercaseString;
    return [[folded componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
}

SGLyricsAsk SGGeniusLyricsAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    if (!query.title.length) { done(nil); return; }
    NSString *q = query.artist.length ? [NSString stringWithFormat:@"%@ %@", query.title, query.artist] : query.title;
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://genius.com/api/search/multi"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:q]];
    NSMutableURLRequest *search = [NSMutableURLRequest requestWithURL:components.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
    [search setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
    [[NSURLSession.sharedSession dataTaskWithRequest:search completionHandler:^(NSData *data, NSURLResponse *reply, NSError *error) {
        NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *response = [root isKindOfClass:NSDictionary.class] ? root[@"response"] : nil;
        NSString *pageURL = nil;
        for (NSDictionary *section in [response[@"sections"] isKindOfClass:NSArray.class] ? response[@"sections"] : @[]) {
            for (NSDictionary *hit in [section[@"hits"] isKindOfClass:NSArray.class] ? section[@"hits"] : @[]) {
                NSDictionary *song = hit[@"result"];
                if (![song isKindOfClass:NSDictionary.class]) continue;
                NSString *title = song[@"title"];
                NSString *artist = song[@"primary_artist"][@"name"];
                if ([matchFold(title) isEqualToString:matchFold(query.title)] &&
                    (!query.artist.length || !artist.length || [matchFold(artist) containsString:matchFold(query.artist)] || [matchFold(query.artist) containsString:matchFold(artist)])) {
                    pageURL = song[@"url"];
                    break;
                }
            }
            if (pageURL) break;
        }
        if (!pageURL) { dispatch_async(dispatch_get_main_queue(), ^{ done(nil); }); return; }
        NSMutableURLRequest *page = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:pageURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
        [page setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
        [[NSURLSession.sharedSession dataTaskWithRequest:page completionHandler:^(NSData *pageData, NSURLResponse *pageReply, NSError *pageError) {
            NSString *html = pageData ? [[NSString alloc] initWithData:pageData encoding:NSUTF8StringEncoding] : nil;
            NSMutableArray<NSString *> *chunks = [NSMutableArray array];
            NSRegularExpression *containers = [NSRegularExpression regularExpressionWithPattern:@"<div[^>]*data-lyrics-container=\"true\"[^>]*>(.*?)</div>" options:NSRegularExpressionDotMatchesLineSeparators error:nil];
            if (html) for (NSTextCheckingResult *match in [containers matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
                NSString *chunk = [html substringWithRange:[match rangeAtIndex:1]];
                chunk = [chunk stringByReplacingOccurrencesOfString:@"<br>" withString:@"\n" options:NSRegularExpressionSearch range:NSMakeRange(0, chunk.length)];
                chunk = [chunk stringByReplacingOccurrencesOfString:@"<br />" withString:@"\n" options:NSLiteralSearch range:NSMakeRange(0, chunk.length)];
                NSString *text = plainText(chunk);
                if (text.length) [chunks addObject:text];
            }
            NSMutableArray<NSString *> *lines = [NSMutableArray array];
            for (NSString *chunk in chunks) for (NSString *line in [chunk componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (trimmed.length) [lines addObject:trimmed];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!lines.count) { done(nil); return; }
                SGLyricsResult *result = [SGLyricsResult new];
                result.provider = @"Genius";
                result.synced = NO;
                result.wordTimed = NO;
                result.karaokeLines = SGKaraokeStaticLines(lines);
                NSArray<NSNumber *> *starts;
                NSArray<NSString *> *texts;
                SGLyricsPageLines(result.karaokeLines, &starts, &texts);
                result.starts = starts;
                result.texts = texts;
                result.title = query.title;
                result.artist = query.artist;
                done(result);
            });
        }] resume];
    }] resume];
};
