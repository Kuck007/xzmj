//
//  CustomerPickerView.swift
//  杏子美甲管理系统
//
//  可复用的"选择客户"组件：
//  1. 拼音排序 + 拼音搜索（姓名/拼音首字母/电话）
//  2. 点击行弹出搜索弹窗；已选客户时显示姓名 + 电话
//

import Foundation
import SwiftUI

// MARK: - 拼音工具

/// 拼音转换缓存（名字不变零转换）。ICU applyingTransform 昂贵，200 客户排序约 3200 次调用。
private var pinyinCache: [String: String] = [:]

/// 将中文转成可排序/可搜索的拉丁拼音串（"王五" → "wang wu"；英文/数字原样保留）
func pinyinSortKey(_ name: String) -> String {
    if let cached = pinyinCache[name] { return cached }
    let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
    let key = (latin.applyingTransform(.stripCombiningMarks, reverse: false) ?? latin)
        .lowercased()
    pinyinCache[name] = key
    return key
}

/// 拼音比较器（中文按拼音排，其余按原字符排），用于客户列表排序
func pinyinLess(_ a: String, _ b: String) -> Bool {
    let ka = pinyinSortKey(a)
    let kb = pinyinSortKey(b)
    if ka == kb { return a < b }
    return ka < kb
}

/// 姓名全拼首字母（每个字取拼音首字母拼接）：王丽 → "WL"，陈颖 → "CY"
func pinyinInitial(_ name: String) -> String {
    return name.compactMap { char in
        let key = pinyinSortKey(String(char))
        guard let first = key.first, first.isLetter else { return nil }
        return String(first).uppercased()
    }.joined()
}

/// 客户是否匹配搜索词（支持 姓名 / 全拼音 / 拼音首字母 / 电话）
func customerMatches(_ customer: Customer, text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespaces).lowercased()
    if t.isEmpty { return true }
    if customer.name.lowercased().contains(t) { return true }
    // 电话：去掉分隔符后，支持任意位置连续数字匹配（2位及以上才匹配，1位太宽泛无意义）
    if !customer.phone.isEmpty && t.count >= 2 && t.allSatisfy({ $0.isNumber }) {
        let digits = customer.phone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        if digits.contains(t) { return true }
    }
    // 全拼音：去掉拼音间空格，支持 "wang"、"wangyu"、"wangyutong"
    if pinyinSortKey(customer.name).replacingOccurrences(of: " ", with: "").contains(t) { return true }
    // 全名首字母前缀匹配：王丽→"wl"，陈颖→"cy"；顺序必须正确，"yc"不匹配陈颖
    if pinyinInitial(customer.name).lowercased().hasPrefix(t) { return true }
    return false
}

// MARK: - 表单行组件（整行展示当前选择，点击弹出搜索弹窗）

struct CustomerField: View {
    @Binding var customerId: UUID?
    let customers: [Customer]
    @State private var showingPicker = false

    private var selected: Customer? { customers.first { $0.id == customerId } }

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            HStack {
                if let c = selected {
                    Text(c.name + (c.phone.isEmpty ? "" : " · " + c.phone))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                } else {
                    Text("请选择客户")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingPicker) {
            CustomerSearchSheet(customerId: $customerId, customers: customers)
                
        }
    }
}

// MARK: - 客户搜索弹窗

struct CustomerSearchSheet: View {
    @Binding var customerId: UUID?
    let customers: [Customer]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var sorted: [Customer] { customers.sorted { pinyinLess($0.name, $1.name) } }
    private var filtered: [Customer] { sorted.filter { customerMatches($0, text: searchText) } }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏：标题 + 搜索框 + X
            HStack(spacing: 10) {
                Text("选择客户").font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("姓名 / 拼音 / 电话", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .frame(width: 220)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                List {
                    if filtered.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "暂无客户" : "无匹配客户",
                            systemImage: "person.2",
                            description: Text(searchText.isEmpty ? "请先在客户信息模块添加客户" : "尝试更换关键词")
                        )
                    } else {
                        ForEach(filtered) { c in
                            Button {
                                customerId = c.id
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.name)
                                        Text(c.phone.isEmpty ? "未填写电话" : c.phone)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if c.membershipLevel != "普通" {
                                        Text(c.membershipLevel)
                                            .font(.caption2)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(membershipColor(c.membershipLevel), in: Capsule())
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(c.id)
                        }
                    }
                }
                .onChange(of: searchText) { _, _ in
                    if let first = filtered.first {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420, idealHeight: 540, maxHeight: 680)
        .onAppear { isSearchFocused = true }
    }
}