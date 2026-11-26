#import <Foundation/Foundation.h>
#import <signal.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#include "tapcore.h"

extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
#define MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK 5
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT      6

static void raiseJetsamLimit(void) {
    int rc = memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), 512, NULL, 0);
    if (rc != 0) {
        memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK, getpid(), 512, NULL, 0);
    }
}

int main(int argc, char *argv[]) {
    signal(SIGPIPE, SIG_IGN);
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    raiseJetsamLimit();

    @autoreleasepool {
        if (tapcore_core_init() != 0) {
            return 1;
        }
        tapcore_core_start_ipc();
        tapcore_runner_load_config();

        NSDictionary *cfg = tapcore_runner_get_config();
        int webPort = [cfg[@"web_port"] intValue] ?: 8080;
        int fbPort  = [cfg[@"fallback_port"] intValue] ?: 8088;

        if (tapcore_web_start(webPort, fbPort) != 0) {
            tapcore_log("ERR", "Failed to start Web Studio HTTP server");
        }

        // Optional CLI argument: run a specific script immediately
        const char *cliScript = NULL;
        for (int i = 1; i < argc; i++) {
            if (argv[i][0] != '-') {
                cliScript = argv[i];
                break;
            }
        }
        if (cliScript) {
            NSString *err = nil;
            tapcore_runner_play(cliScript, &err);
        } else {
            tapcore_runner_autostart_if_configured();
        }

        // Main daemon run loop stays alive forever to serve Web/App Studio & script runner
        for (;;) {
            sleep(60);
        }
    }
    return 0;
}
