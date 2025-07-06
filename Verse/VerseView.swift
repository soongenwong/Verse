import SwiftUI

// MARK: - API Key Manager
// Helper to read the API key from Secrets.plist
struct APIKeyManager {
    static func getGroqAPIKey() -> String? {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let key = dict["GROQ_API_KEY"] as? String else {
            print("ERROR: Could not find Secrets.plist or 'GroqAPIKey' key in it. Please follow setup instructions.")
            return nil
        }
        return key
    }
}

// MARK: - State Management
// Enum to manage the different states of our view during the API call
enum LoadingState {
    case idle
    case loading
    case success(VerseAnalysis)
    case error(String)
}

// MARK: - Codable Models for API
// These structs must now be Codable to work with the API response.
// We use CodingKeys to map the AI's snake_case JSON to Swift's camelCase.

struct VerseAnalysis: Codable, Identifiable {
    var id: String { verseReference } // Use a stable identifier
    
    let verseReference: String
    let verseText: String
    let context: String
    let exegesis: String
    let themes: String
    let crossReferences: [CrossReference]

    enum CodingKeys: String, CodingKey {
        case verseReference = "verse_reference"
        case verseText = "verse_text"
        case context
        case exegesis
        case themes
        case crossReferences = "cross_references"
    }
}

struct CrossReference: Codable, Identifiable {
    let id = UUID()
    let reference: String
    let text: String
    
    // Conformance to Codable is automatic as properties are Codable.
    // We add CodingKeys in case the JSON is ever snake_case.
    enum CodingKeys: String, CodingKey {
        case reference
        case text
    }
}

// Models for the Groq API request and response structure
struct GroqRequestBody: Codable {
    let messages: [GroqMessage]
    let model: String
    let temperature: Double = 0.5
    let max_tokens: Int = 2048
    let top_p: Double = 1
    let stop: String? = nil
    let stream: Bool = false
}

struct GroqResponse: Codable {
    let choices: [GroqChoice]
}

struct GroqChoice: Codable {
    let message: GroqMessage
}

struct GroqMessage: Codable {
    let role: String
    let content: String
}


// Enum for the tabs (no changes needed here)
enum AnalysisTab: String, CaseIterable, Identifiable {
    case context = "Context"
    case exegesis = "Exegesis"
    case themes = "Themes"
    case crossRef = "Cross-Ref"
    
    var id: String { self.rawValue }
}


// MARK: - Main View
struct VerseView: View {
    
    @State private var verseInput: String = "John 3:16"
    @State private var loadingState: LoadingState = .idle
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // MARK: 1. Input Section
                HStack {
                    TextField("Enter a verse (e.g., Romans 8:28)", text: $verseInput)
                        .textFieldStyle(.roundedBorder)
                    
                    Button("Analyze") {
                        Task {
                            await generateAnalysis()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(verseInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
                
                Divider()
                
                // MARK: 2. Dynamic Content Area
                // This view now changes based on the loading state
                switch loadingState {
                case .idle:
                    VStack {
                        Spacer()
                        Image(systemName: "text.book.closed")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Enter a verse and tap 'Analyze' to begin.")
                            .foregroundColor(.secondary)
                            .padding(.top)
                        Spacer()
                    }
                case .loading:
                    VStack {
                        Spacer()
                        ProgressView("Generating Analysis...")
                        Spacer()
                    }
                case .success(let analysis):
                    // On success, we show the tabbed interface
                    AnalysisDetailView(analysis: analysis)
                case .error(let errorMessage):
                    VStack {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.red)
                        Text("An Error Occurred")
                            .font(.headline)
                            .padding(.top)
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                        Spacer()
                    }
                }
            }
            .navigationTitle("Verse Explorer")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // MARK: - Networking Function
    private func generateAnalysis() async {
        // Guard against missing API key
        guard let apiKey = APIKeyManager.getGroqAPIKey() else {
            await MainActor.run {
                self.loadingState = .error("API Key not found. Please check your Secrets.plist configuration.")
            }
            return
        }
        
        // Set state to loading
        await MainActor.run { self.loadingState = .loading }
        
        // Define the prompt for the AI
        let systemPrompt = """
        You are a biblical analysis expert. For the given verse, generate a multi-layered analysis.
        Your entire response MUST be a single, valid JSON object with NO markdown formatting (like ```json).
        The JSON object must have the following exact structure:
        {
          "verse_reference": "string",
          "verse_text": "string",
          "context": "string (Historical and literary background)",
          "exegesis": "string (A straightforward explanation of the text)",
          "themes": "string (Key theological doctrines present, use bullet points)",
          "cross_references": [
            { "reference": "string", "text": "string" },
            { "reference": "string", "text": "string" },
            { "reference": "string", "text": "string" },
            { "reference": "string", "text": "string" },
            { "reference": "string", "text": "string" }
          ]
        }
        """

        let requestBody = GroqRequestBody(
            messages: [
                GroqMessage(role: "system", content: systemPrompt),
                GroqMessage(role: "user", content: "Generate the analysis for: \(verseInput)")
            ],
            model: "llama3-8b-8192"
        )
        
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            await MainActor.run { self.loadingState = .error("Invalid API URL.") }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
            
            let (data, _) = try await URLSession.shared.data(for: request)
            
            // First, decode the main Groq response
            let groqResponse = try JSONDecoder().decode(GroqResponse.self, from: data)
            
            guard let contentString = groqResponse.choices.first?.message.content else {
                throw URLError(.cannotParseResponse)
            }
            
            // The AI's response is a string containing JSON. We need to decode that string.
            guard let jsonData = contentString.data(using: .utf8) else {
                throw URLError(.cannotParseResponse)
            }
            
            let finalAnalysis = try JSONDecoder().decode(VerseAnalysis.self, from: jsonData)
            
            // Switch to main thread to update UI state
            await MainActor.run {
                self.loadingState = .success(finalAnalysis)
            }
            
        } catch {
            // Switch to main thread to update UI state with error
            await MainActor.run {
                print("API Error: \(error)")
                self.loadingState = .error("Failed to generate or parse analysis. Error: \(error.localizedDescription)")
            }
        }
    }
}


// MARK: - AnalysisDetailView (The UI for a successful response)
// We've moved the successful UI into its own view to keep the main view clean.
struct AnalysisDetailView: View {
    let analysis: VerseAnalysis
    @State private var selectedTab: AnalysisTab = .context

    var body: some View {
        VStack(spacing: 0) {
            // 1. Verse Header
            VStack(alignment: .leading, spacing: 10) {
                Text(analysis.verseReference)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("\"\(analysis.verseText)\"")
                    .font(.title3)
                    .italic()
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))

            // 2. Tab Selector
            Picker("Analysis Lens", selection: $selectedTab.animation(.easeInOut)) {
                ForEach(AnalysisTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            // 3. Dynamic Content Area
            ScrollView {
                contentForSelectedTab()
                    .padding(.horizontal)
                    .padding(.bottom)
            }
            .frame(maxHeight: .infinity)
        }
    }
    
    @ViewBuilder
    private func contentForSelectedTab() -> some View {
        switch selectedTab {
        case .context:
            AnalysisTextView(title: "Historical & Literary Context", content: analysis.context)
        case .exegesis:
            AnalysisTextView(title: "Exegesis (Direct Interpretation)", content: analysis.exegesis)
        case .themes:
            AnalysisTextView(title: "Theological Themes", content: analysis.themes)
        case .crossRef:
            CrossReferenceListView(title: "Illuminating Cross-References", references: analysis.crossReferences)
        }
    }
}


// MARK: - Reusable Subviews (No changes needed here)
struct AnalysisTextView: View {
    let title: String
    let content: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(content)
                .font(.body)
                .lineSpacing(5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CrossReferenceListView: View {
    let title: String
    let references: [CrossReference]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            
            ForEach(references) { ref in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ref.reference)
                        .fontWeight(.bold)
                    Text(ref.text)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray5))
                .cornerRadius(8)
                .padding(.bottom, 4)
            }
        }
    }
}


// MARK: - Preview
// The preview will show the idle state, as it cannot make a network call.
struct VerseView_Previews: PreviewProvider {
    static var previews: some View {
        VerseView()
    }
}
