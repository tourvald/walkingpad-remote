import Combine

final class TrainingUIObservationBoundary: ObservableObject {
    private var cancellables: Set<AnyCancellable> = []

    init(signals: [AnyPublisher<Void, Never>]) {
        Publishers.MergeMany(signals)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}
