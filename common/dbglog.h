// debug —— 统一调试日志：~/.vfdpeq_gui.debug.log
// 所有组件（GUI/ENG/DRV）共用一个文件，O_APPEND 原子追加，多进程安全。
// ⚠️ 集中回溯清理标记：所有 //debug 注释的调用点在产品稳定后统一移除。
#ifndef PEQ_DBGLOG_H
#define PEQ_DBGLOG_H

#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static volatile int peq_dbg_fd = -1;   // volatile: 阻断编译器对 fd 状态的跨函数消除（O2 下会吞掉整条日志链）
static const char* peq_dbg_tag = "APP";

// 初始化：tag 为组件标签（GUI / ENG / DRV）
// 路径优先级：编译期宏 PEQ_DEBUG_LOG_PATH（驱动用——helper 进程 HOME=/var/root，
// 必须在构建期写死用户主目录绝对路径）> 运行期 $HOME
#ifdef PEQ_DEBUG_LOG_PATH
#define PEQ_DBG_OPEN_TARGET PEQ_DEBUG_LOG_PATH   // debug: 编译期固定路径（驱动 helper 进程）
#else
#define PEQ_DBG_OPEN_TARGET NULL                 // debug: 运行期解析 $HOME
#endif
static void peq_dbg_init(const char* tag) {
    const char* target = PEQ_DBG_OPEN_TARGET;
    char pathbuf[512];
    if (!target) {                               // 运行期解析 $HOME/.vfdpeq_gui.debug.log
        const char* home = getenv("HOME");
        snprintf(pathbuf, sizeof(pathbuf), "%s/.vfdpeq_gui.debug.log", home ? home : "/tmp");
        target = pathbuf;
    }
    peq_dbg_tag = tag;
    peq_dbg_fd = open(target, O_WRONLY | O_APPEND | O_CREAT, 0666);
}

// 追加一条：`MM-DD HH:MM:SS.mmm [TAG pid] message`
// noinline+used：防止 O2 把整条日志调用链消除（驱动侧实测 O2 会消掉格式串）
__attribute__((noinline, used)) static void peq_dbg(const char* fmt, ...) {
    if (peq_dbg_fd < 0) return;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    char ts[40];
    strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", &tm);
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    dprintf(peq_dbg_fd, "%s.%03d [%s %d] %s\n", ts, (int)(tv.tv_usec / 1000), peq_dbg_tag,
            (int)getpid(), msg);
}

#endif // PEQ_DBGLOG_H
