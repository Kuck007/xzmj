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

/// 将中文转成可排序/可搜索的拉丁拼音串（"王五" → "wang wu"；英文/数字原样保留）
func pinyinSortKey(_ name: String) -> String {
    let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
    return (latin.applyingTransform(.stripCombiningMarks, reverse: false) ?? latin)
        .lowercased()
}

/// 拼音比较器（中文按拼音排，其余按原字符排），用于客户列表排序
func pinyinLess(_ a: String, _ b: String) -> Bool {
    let ka = pinyinSortKey(a)
    let kb = pinyinSortKey(b)
    if ka == kb { return a < b }
    return ka < kb
}

/// 姓名首字母（用于搜索 & 未来字母分组）：中文取拼音首字母，非字母归为 #
func pinyinInitial(_ name: String) -> String {
    guard let first = pinyinSortKey(name).first else { return "#" }
    return first.isLetter ? String(first).uppercased() : "#"
}

/// 客户是否匹配搜索词（支持 姓名 / 全拼音 / 拼音首字母 / 电话）
func customerMatches(_ customer: Customer, text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespaces).lowercased()
    if t.isEmpty { return true }
    if customer.name.lowercased().contains(t) { return true }
    if !customer.phone.isEmpty && customer.phone.contains(t) { return true }
    if pinyinSortKey(customer.name).contains(t) { return true }
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

    private var sorted: [Customer] { customers.sorted { pinyinLess($0.name, $1.name) } }
    private var filtered: [Customer] { sorted.filter { customerMatches($0, text: searchText) } }

    var body: some View {
        NavigationStack {
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
                    }
                }
            }
            .searchable(text: $searchText, prompt: "姓名 / 拼音 / 电话")
            .navigationTitle("选择客户")
        }
        .frame(minWidth: 420, minHeight: 420, idealHeight: 540, maxHeight: 680)
    }
}