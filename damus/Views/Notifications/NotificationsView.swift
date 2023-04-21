//
//  NotificationsView.swift
//  damus
//
//  Created by William Casarin on 2023-02-21.
//

import SwiftUI

enum FriendFilter: String {
    case all
    case friends
    
    func filter(contacts: Contacts, pubkey: String) -> Bool {
        switch self {
        case .all:
            return true
        case .friends:
            return contacts.is_in_friendosphere(pubkey)
        }
    }
}

class NotificationFilter: ObservableObject, Equatable {
    @Published var state: NotificationFilterState
    @Published var fine_filter: FriendFilter
    
    static func == (lhs: NotificationFilter, rhs: NotificationFilter) -> Bool {
        return lhs.state == rhs.state && lhs.fine_filter == rhs.fine_filter
    }
    
    init() {
        self.state = .all
        self.fine_filter = .all
    }
    
    init(state: NotificationFilterState, fine_filter: FriendFilter) {
        self.state = state
        self.fine_filter = fine_filter
    }
    
    func toggle_fine_filter() {
        switch self.fine_filter {
        case .all:
            self.fine_filter = .friends
        case .friends:
            self.fine_filter = .all
        }
    }
    
    var fine_filter_binding: Binding<Bool> {
        Binding(get: {
            return self.fine_filter == .friends
        }, set: { v in
            self.fine_filter = v ? .friends : .all
        })
    }
    
    func filter(contacts: Contacts, items: [NotificationItem]) -> [NotificationItem] {
        
        return items.reduce(into: []) { acc, item in
            if !self.state.filter(item) {
                return
            }
            
            if let item = item.filter({ self.fine_filter.filter(contacts: contacts, pubkey: $0.pubkey) }) {
                acc.append(item)
            }
        }
    }
}

enum NotificationFilterState: String {
    case all
    case zaps
    case replies
    
    func is_other( item: NotificationItem) -> Bool {
        return item.is_zap == nil && item.is_reply == nil
    }
    
    func filter(_ item: NotificationItem) -> Bool {
        switch self {
        case .all:
            return true
        case .replies:
            return item.is_reply != nil
        case .zaps:
            return item.is_zap != nil
        }
    }
}

struct NotificationsView: View {
    let state: DamusState
    @ObservedObject var notifications: NotificationsModel
    @StateObject var filter_state: NotificationFilter = NotificationFilter()
    
    @Environment(\.colorScheme) var colorScheme
    
    var mystery: some View {
        VStack(spacing: 20) {
            Text("Wake up, \(Profile.displayName(profile: state.profiles.lookup(id: state.pubkey), pubkey: state.pubkey).display_name)", comment: "Text telling the user to wake up, where the argument is their display name.")
            Text("You are dreaming...", comment: "Text telling the user that they are dreaming.")
        }
        .id("what")
    }
    
    var body: some View {
        TabView(selection: $filter_state.state) {
            // This is needed or else there is a bug when switching from the 3rd or 2nd tab to first. no idea why.
            mystery
            
            NotificationTab(
                NotificationFilter(
                    state: .all,
                    fine_filter: filter_state.fine_filter
                )
            )
            .tag(NotificationFilterState.all)
            
            NotificationTab(
                NotificationFilter(
                    state: .zaps,
                    fine_filter: filter_state.fine_filter
                )
            )
            .tag(NotificationFilterState.zaps)
            
            NotificationTab(
                NotificationFilter(
                    state: .replies,
                    fine_filter: filter_state.fine_filter
                )
            )
            .tag(NotificationFilterState.replies)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if would_filter_non_friends_from_notifications(contacts: state.contacts, state: self.filter_state.state, items: self.notifications.notifications) {
                    FriendsButton(enabled: self.filter_state.fine_filter_binding)
                }
            }
        }
        .onChange(of: filter_state.fine_filter) { val in
            save_friend_filter(pubkey: state.pubkey, filter: val)
        }
        .onChange(of: filter_state.state) { val in
            save_notification_filter_state(pubkey: state.pubkey, state: val)
        }
        .onAppear {
            let state = load_notification_filter_state(pubkey: state.pubkey)
            self.filter_state.fine_filter = state.fine_filter
            self.filter_state.state = state.state
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                CustomPicker(selection: $filter_state.state, content: {
                    Text("All", comment: "Label for filter for all notifications.")
                        .tag(NotificationFilterState.all)
                    
                    Text("Zaps", comment: "Label for filter for zap notifications.")
                        .tag(NotificationFilterState.zaps)
                    
                    Text("Mentions", comment: "Label for filter for seeing mention notifications (replies, etc).")
                        .tag(NotificationFilterState.replies)
                    
                })
                Divider()
                    .frame(height: 1)
            }
            .background(colorScheme == .dark ? Color.black : Color.white)
        }
    }
    
    func NotificationTab(_ filter: NotificationFilter) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading) {
                    Color.white.opacity(0)
                        .id("startblock")
                        .frame(height: 5)
                    ForEach(filter.filter(contacts: state.contacts, items: notifications.notifications), id: \.id) { item in
                        NotificationItemView(state: state, item: item)
                    }
                }
                .background(GeometryReader { proxy -> Color in
                    DispatchQueue.main.async {
                        handle_scroll_queue(proxy, queue: self.notifications)
                    }
                    return Color.clear
                })
            }
            .coordinateSpace(name: "scroll")
            .onReceive(handle_notify(.scroll_to_top)) { notif in
                let _ = notifications.flush(state)
                self.notifications.should_queue = false
                scroll_to_event(scroller: scroller, id: "startblock", delay: 0.0, animate: true, anchor: .top)
            }
        }
        .onAppear {
            let _ = notifications.flush(state)
        }
    }
}

struct NotificationsView_Previews: PreviewProvider {
    static var previews: some View {
        NotificationsView(state: test_damus_state(), notifications: NotificationsModel(), filter_state: NotificationFilter())
    }
}

func notification_filter_state_key(pubkey: String) -> String {
    return pk_setting_key(pubkey, key: "notification_filter_state")
}

func friend_filter_key(pubkey: String) -> String {
    return pk_setting_key(pubkey, key: "friend_filter")
}

func load_notification_filter_state(pubkey: String) -> NotificationFilter {
    let key = notification_filter_state_key(pubkey: pubkey)
    let fine_key = friend_filter_key(pubkey: pubkey)
    
    let state_str = UserDefaults.standard.string(forKey: key)
    let state = (state_str.flatMap { NotificationFilterState(rawValue: $0) }) ?? .all
    
    let filter_str = UserDefaults.standard.string(forKey: fine_key)
    let filter = (filter_str.flatMap { FriendFilter(rawValue: $0) } ) ?? .all
    
    return NotificationFilter(state: state, fine_filter: filter)
}


func save_notification_filter_state(pubkey: String, state: NotificationFilterState)  {
    let key = notification_filter_state_key(pubkey: pubkey)
    
    UserDefaults.standard.set(state.rawValue, forKey: key)
}

func save_friend_filter(pubkey: String, filter: FriendFilter) {
    let key = friend_filter_key(pubkey: pubkey)
    
    UserDefaults.standard.set(filter.rawValue, forKey: key)
}

func would_filter_non_friends_from_notifications(contacts: Contacts, state: NotificationFilterState, items: [NotificationItem]) -> Bool {
    for item in items {
        // this is only valid depending on which tab we're looking at
        if !state.filter(item) {
            continue
        }
        
        if item.would_filter({ ev in FriendFilter.friends.filter(contacts: contacts, pubkey: ev.pubkey) }) {
            return true
        }
    }
    
    return false
}

