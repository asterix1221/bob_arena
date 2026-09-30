// reliability/dedup_window.hpp
//
// Окно недавно обработанных sequenceNumber на стороне получателя (сервера).
// Из-за повторной передачи (потерян ACK, либо RTO клиента сработал раньше,
// чем дошёл ACK) сервер может получить один и тот же надёжный пакет
// несколько раз. Игровой эффект (выстрел) нужно применить ровно один раз,
// а ACK — отправлять на КАЖДУЮ копию (исходный ACK мог потеряться).
//
// Окно хранит последние `capacity` номеров; при переполнении вытесняется
// самый старый. Ёмкость должна с запасом перекрывать число пакетов, которое
// отправитель успевает выпустить за maxAttempts * maxRTO (по умолчанию
// 5 * 3 с), иначе очень поздняя копия будет принята за новый пакет.
// Модуль не зависит от сокетов и часов.

#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <unordered_set>

namespace reliability {

class DedupWindow {
public:
    explicit DedupWindow(std::size_t capacity = 1024) : capacity_(capacity == 0 ? 1 : capacity) {}

    // Возвращает true, если sequence видим впервые (пакет нужно обработать) и
    // запоминает его; false — дубликат (эффект применять НЕ нужно).
    bool MarkProcessed(std::uint16_t sequence);

    bool Contains(std::uint16_t sequence) const { return seen_.count(sequence) > 0; }
    std::size_t Size() const { return order_.size(); }
    std::size_t Capacity() const { return capacity_; }

private:
    std::size_t capacity_;
    std::deque<std::uint16_t> order_;       // порядок поступления (для вытеснения)
    std::unordered_set<std::uint16_t> seen_; // быстрая проверка принадлежности
};

} // namespace reliability
