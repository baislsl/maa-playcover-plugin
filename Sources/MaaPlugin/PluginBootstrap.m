//
//  PluginBootstrap.m
//  MaaPlugin
//
//  PlayTools' UserPluginLoader only calls dlopen() on every dylib found in
//  Frameworks/UserPlugins/ (see UserPluginLoader.swift), so the plugin has to
//  bring its own entry point. The loader runs during application launch, which
//  is early enough that a constructor can simply hop to the main queue and ask
//  the Swift side to start the MaaTools server.
//

#import <Foundation/Foundation.h>

extern void MaaPluginStart(void);

__attribute__((constructor))
static void MaaPluginBootstrap(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        MaaPluginStart();
    });
}
