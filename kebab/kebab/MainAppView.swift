import SwiftUI

struct MainAppView: View {
    var body: some View {
        VStack {
            Text("Main App")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .foregroundColor(.white)
    }
}

#Preview {
    MainAppView()
}
