// 测试用的最小断言工具 (三个测试程序共用)。
#pragma once
#include <cstdio>
#include <string>
#include <string_view>
#include <fstream>
#include <sstream>

namespace tst {

inline int g_failures = 0;

inline void report(const char* file, int line, const char* expr) {
    std::printf("FAIL %s:%d  %s\n", file, line, expr);
    ++g_failures;
}

inline int finish(const char* name) {
    if (g_failures) std::printf("\n[%s] %d 项断言失败\n", name, g_failures);
    else            std::printf("\n[%s] 全部通过\n", name);
    return g_failures ? 1 : 0;
}

// 读取 Tests/fixtures 下的样本文件。路径由 FIXTURE_DIR 宏给出 (run.sh 传入)。
inline std::string fixture(std::string_view name) {
    std::string path = std::string(FIXTURE_DIR) + "/" + std::string(name);
    std::ifstream in(path, std::ios::binary);
    if (!in) { std::printf("FAIL 读不到样本文件: %s\n", path.c_str()); ++g_failures; return {}; }
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

} // namespace tst

#define CHECK(cond) do { if (!(cond)) tst::report(__FILE__, __LINE__, #cond); } while (0)
