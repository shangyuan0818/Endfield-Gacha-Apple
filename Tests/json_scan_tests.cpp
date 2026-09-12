// JsonScan.h 的单元测试。直接 include 真实头文件, 不做任何转录。
//
// 覆盖两轮外部审查点名的全部反例:
//   - 正文在 list 之前 / 之后截断 (IsCompleteObjectDocument 必须拒绝)
//   - 数组元素之间缺逗号、尾逗号、非对象元素
//   - 对象成员之间缺逗号、尾逗号
//   - 嵌套同名键遮蔽 (FindMember 只认本层)
//   - "值恰好等于键名" 不应被误判成键
//   - 严格校验器: {"a":} / {"a":1,} / 01 / 非法转义 / 裸控制字符 / 字符串外的 NUL
#include "../Endfield-Gacha/ObjC/JsonScan.h"
#include "test_support.h"

using namespace efjson;

static int countObjects(std::string_view arr, ArrayScan* out) {
    int n = 0;
    const ArrayScan s = ForEachObjectIn(arr, [&](std::string_view){ ++n; });
    if (out) *out = s;
    return n;
}

int main() {
    // ---------- IsCompleteObjectDocument: 截断闸门 ----------
    CHECK(IsCompleteObjectDocument(R"({"code":0,"data":{"list":[],"hasMore":false}})"));
    CHECK(IsCompleteObjectDocument("  {\"a\":1}\n\n "));
    CHECK(!IsCompleteObjectDocument(R"({"code":0,"data":)"));                                    // list 之前截断
    CHECK(!IsCompleteObjectDocument(R"({"code":0,"data":{"list":[{"seqId":"1"}],"hasMore":)"));   // hasMore 之后截断
    CHECK(!IsCompleteObjectDocument(R"({"code":0,"data":{"list":[{"seqId":"1"})"));               // list 之内截断
    CHECK(!IsCompleteObjectDocument(R"({"a":1} trailing)"));
    CHECK(!IsCompleteObjectDocument(R"([{"a":1}])"));                                             // 顶层不是对象
    CHECK(!IsCompleteObjectDocument(""));
    CHECK(!IsCompleteObjectDocument(R"({"s":"未闭合)"));

    // ---------- ForEachObjectIn: 元素类型与分隔逗号 ----------
    ArrayScan st;
    CHECK(countObjects("[]",   &st) == 0 && st == ArrayScan::Ok);
    CHECK(countObjects("[  ]", &st) == 0 && st == ArrayScan::Ok);
    CHECK(countObjects(R"([{"a":1},{"b":"}"}])", &st) == 2 && st == ArrayScan::Ok);
    countObjects(R"([{"a":1}{"b":2}])", &st); CHECK(st == ArrayScan::Malformed);   // 缺逗号
    countObjects(R"([{"a":1},])",        &st); CHECK(st == ArrayScan::Malformed);   // 尾逗号
    countObjects(R"([[],{"a":1}])",      &st); CHECK(st == ArrayScan::Malformed);   // 非对象元素
    countObjects(R"([{"a":1},null])",    &st); CHECK(st == ArrayScan::Malformed);   // null 元素
    countObjects(R"([{"a":1},{"b":2)",   &st); CHECK(st == ArrayScan::Malformed);   // 截断
    countObjects(R"([{"a":{"b":[1,2]}}])", &st); CHECK(st == ArrayScan::Ok);        // 嵌套

    // ---------- FindMember: 只认本层, 且本层严格 ----------
    {
        const std::string_view doc = R"({"x":{"list":[1,2]},"list":[{"a":1}],"n":null,"s":"list"})";
        CHECK(FindMember(doc, "list").kind == ValueKind::Array);
        CHECK(FindMember(doc, "list").text == R"([{"a":1}])");          // 不是 x.list
        CHECK(FindMember(doc, "n").kind == ValueKind::Null);
        CHECK(FindMember(doc, "nope").kind == ValueKind::None && !FindMember(doc, "nope").malformed);
        CHECK(FindMember(doc, "s").kind == ValueKind::String && FindMember(doc, "s").text == "list");
        CHECK(FindMember(R"({"a":)", "a").malformed);
        CHECK(FindMember(R"({"a":1 "b":2})", "b").malformed);           // 成员间缺逗号
        CHECK(FindMember(R"({"a":1,})", "zz").malformed);               // 尾逗号
        CHECK(FindMember(R"({"a":1,"b":true})", "b").kind == ValueKind::Bool);
        CHECK(FindMember("{}", "a").kind == ValueKind::None && !FindMember("{}", "a").malformed);
        // 结构坏在目标键【之后】时也必须报 malformed, 而不是"读到了就算数"
        CHECK(FindMember(R"({"id":"1","item_id":})", "nope").malformed);
    }

    // ---------- SkipValue: 括号交叉 ----------
    { ValueKind k = ValueKind::None; CHECK(SkipValue(R"({"a":[1,2}])", 0, k) == std::string_view::npos); }
    { ValueKind k = ValueKind::None;
      CHECK(SkipValue(R"([{"a":1}])", 0, k) != std::string_view::npos && k == ValueKind::Array); }

    // ---------- FirstElement ----------
    {
        const ValueRef e = FirstElement(R"([{"uid":"0","list":[]},{"z":1}])");
        CHECK(e.kind == ValueKind::Object && e.text == R"({"uid":"0","list":[]})");
        CHECK(FirstElement("[ ]").kind == ValueKind::None && !FirstElement("[ ]").malformed);
        CHECK(FirstElement("{}").malformed);
    }

    // ---------- ParseFullInt64 ----------
    {
        long long v = -1;
        CHECK(ParseFullInt64("1006", v) && v == 1006);
        CHECK(!ParseFullInt64("1006oops", v));
        CHECK(!ParseFullInt64("bad-id", v));
        CHECK(!ParseFullInt64("", v));
        CHECK(!ParseFullInt64(" 12", v));
        CHECK(!ParseFullInt64("1180591620717411303424", v));            // 超 int64
        CHECK(ParseFullInt64("-42", v) && v == -42);
    }

    // ---------- 全文路径 (只给服务器报文用) ----------
    {
        int n = 0;
        CHECK(ForEachObjectByKey(R"({"code":0,"data":{"list":[{"a":1},{"b":2}]}})", "list",
                                 [&](std::string_view){ ++n; }) == ArrayScan::Ok);
        CHECK(n == 2);
        n = 0;
        CHECK(ForEachObjectByKey(R"({"code":0,"list":null})", "list",
                                 [&](std::string_view){ ++n; }) == ArrayScan::NotFound);
        n = 0;
        // 值恰好等于键名: 不该被当成键, 应继续往后找
        CHECK(ForEachObjectByKey(R"({"foo":"list","list":[{"a":1}]})", "list",
                                 [&](std::string_view){ ++n; }) == ArrayScan::Ok);
        CHECK(n == 1);
        n = 0;
        CHECK(ForEachObjectByKey(R"({"list":{"a":1}})", "list",
                                 [&](std::string_view){ ++n; }) == ArrayScan::Malformed);
    }

    // ---------- IsStrictJsonValue: 会被逐字节原样回写的片段 ----------
    CHECK(IsStrictJsonValue(R"({"a":1})"));
    CHECK(IsStrictJsonValue(R"({})"));
    CHECK(IsStrictJsonValue(R"([])"));
    CHECK(IsStrictJsonValue(R"({"seqId":"123","kind":"gift_intel_book","gachaTs":1758000000000,"isFree":false,"x":{"a":[1,2.5,-3e10,null,true]}})"));
    CHECK(IsStrictJsonValue("  {\"a\":\"\\u4e2d\\n\"}  "));
    CHECK(IsStrictJsonValue("-0.5e+10"));
    CHECK(!IsStrictJsonValue(R"({"a":})"));
    CHECK(!IsStrictJsonValue(R"({"a" 1,,,"b"::2})"));
    CHECK(!IsStrictJsonValue(R"({"a":1e+-x.5})"));
    CHECK(!IsStrictJsonValue(R"({"a":1,})"));
    CHECK(!IsStrictJsonValue(R"([1,])"));
    CHECK(!IsStrictJsonValue(R"({"a":01})"));
    CHECK(!IsStrictJsonValue(R"({a:1})"));
    CHECK(!IsStrictJsonValue(R"({"a":1)"));
    CHECK(!IsStrictJsonValue(R"({"a":1} junk)"));
    CHECK(!IsStrictJsonValue(R"({"a":"\q"})"));
    CHECK(!IsStrictJsonValue(R"({"a":"\u12g4"})"));
    CHECK(!IsStrictJsonValue("{\"a\":\"x\ty\"}"));                       // 字符串里的裸制表符
    CHECK(!IsStrictJsonValue(R"({"a":1 "b":2})"));
    CHECK(!IsStrictJsonValue(R"([{"a":1}{"b":2}])"));
    CHECK(!IsStrictJsonValue("tru"));
    CHECK(!IsStrictJsonValue(""));
    // 审查反例: 字符串之外的裸 NUL。宽松扫描器把它当空白跳过, 但标准解析器 (Python json /
    // NSJSONSerialization) 一律拒绝 —— 严格校验器负责批准原样回写, 必须与标准一致。
    {
        const std::string nul = tst::fixture("raw_nul_whitespace.invalid.json");
        CHECK(!nul.empty());
        CHECK(nul.find('\0') != std::string::npos);                      // 样本确实含 NUL
        CHECK(!IsStrictJsonValue(std::string_view(nul.data(), nul.size())));
    }
    // 深度上限
    { std::string deep(70, '['); deep += std::string(70, ']'); CHECK(!IsStrictJsonValue(deep)); }
    { std::string ok(40, '[');   ok   += std::string(40, ']'); CHECK(IsStrictJsonValue(ok)); }

    return tst::finish("json_scan");
}
