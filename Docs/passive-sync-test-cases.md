# Test case: Passive HealthKit Sync

Danh sách test case cho passive sync, tập trung vào việc sync giữa nhiều thiết bị và đăng nhập / đăng xuất.

## Giả định của thiết kế đích

Kết quả mong đợi bên dưới dựa trên các giả định sau:

- **Server:** mỗi tài khoản chỉ đăng nhập trên một thiết bị tại một thời điểm. Đăng nhập trên máy mới sẽ đá phiên của máy cũ.
- **Server lưu bước theo khung 5 phút** cho từng tài khoản và lấy giá trị lớn nhất giữa các thiết bị. Thưởng được tính theo phần chênh lệch của ngày.
- **Client:**
  - Anchor gắn với máy, không gắn với tài khoản.
  - Mỗi record chờ gửi phải được gắn `accountId`.
  - App chỉ ghi log và gửi lên server khi đang đăng nhập.
- **Code hiện tại chưa có:** login, `accountId` trên record, việc kiểm tra phiên trước khi gửi, và server gộp theo khung thời gian. Các case liên quan đến những phần này là test cho thiết kế đích, chưa chạy được với code hiện tại.

---

## A. Đăng nhập / đăng xuất trên cùng một máy

| ID | Kịch bản | Kết quả mong đợi |
|---|---|---|
| A1 | Tài khoản A đăng nhập lần đầu trên máy X, giữa ngày | Ghi bước từ đầu ngày hôm nay, hoặc từ thời điểm đăng nhập, tuỳ chính sách (P1). Không đọc lịch sử cũ hơn mốc đó. |
| A2 | A đăng xuất, rồi đăng nhập lại trên X trong cùng ngày | Không gửi lại bước đã được thưởng. Anchor vẫn còn nên chỉ đọc phần mới. Nếu có đọc lại thì server lấy max nên không cộng dồn. |
| A3 | A đăng xuất khi còn record **chờ gửi** | Theo chính sách P2: gửi nốt record trước khi đăng xuất, hoặc giữ lại và gắn với A. **Không được** gửi dưới tài khoản khác. |
| A4 | A đăng xuất, sau đó tài khoản B đăng nhập trên cùng máy X | B không nhận được bước mà A đã nhận trong cùng khoảng thời gian (D1). Record chờ gửi của A không được gửi bằng phiên của B. |
| A5 | Đăng xuất đúng lúc đang sync | Lần sync đang chạy hoặc hoàn tất với phiên cũ, hoặc bị huỷ sạch. Record không bị lưu với trạng thái lửng. Sau khi đăng xuất, không còn lần gửi nào chạy tiếp. |
| A6 | Đã đăng xuất nhưng BGTask hoặc HealthKit wake vẫn đánh thức app | App không ghi log và không gửi gì. Anchor không bị đẩy lên, để lần đăng nhập sau còn đọc được. |
| A7 | Token hết hạn trong lúc đang chạy nền | App làm mới token, hoặc giữ record ở trạng thái chờ. Không coi lỗi 401 là "gửi thất bại vĩnh viễn". |
| A8 | Đăng nhập lại sau nhiều ngày không mở app | Chỉ đọc tới giới hạn mốc của chính sách (ví dụ tối đa 7 ngày). Sample cũ hơn bị server từ chối theo ngày. |

## B. Chuyển sang thiết bị mới (X sang Y), có đá phiên

| ID | Kịch bản | Kết quả mong đợi |
|---|---|---|
| B1 | A dùng X buổi sáng và đã gửi xong. Buổi chiều đăng nhập Y, **iCloud Sức khoẻ bật**, Y sync cả ngày | Y thấy cả sample của X, và các sample đồng bộ giữ nguyên UUID. Server lấy max theo khung, nên tổng ngày không bị đếm hai lần. |
| B2 | Giống B1 nhưng **iCloud Sức khoẻ tắt** | Y chỉ thấy bước của chính Y. Tổng ngày là phần buổi sáng từ X cộng phần buổi chiều từ Y, đúng và không trùng. |
| B3 | X đang offline và còn record chờ gửi, thì A đăng nhập Y. Sau đó X có mạng lại | Server từ chối phiên của X. Theo chính sách P3, server nhận hoặc bỏ dữ liệu của X đến trước thời điểm bị đá. App X hiển thị đã bị đăng xuất, không thử gửi lại mãi. |
| B4 | X bị đá đúng lúc đang gửi | Request trả 401. Record vẫn ở trạng thái chờ hoặc bị huỷ theo P3, không đánh dấu thành công. |
| B5 | A chuyển qua lại X, Y, X trong cùng ngày | Mỗi lần chuyển không cộng dồn. Anchor của X vẫn còn, nên X chỉ đọc phần mới. Tổng ngày bằng tổng max theo từng khung. |
| B6 | Trong ngày, A mang theo cả X (đã bị đá) và Y | Chỉ Y gửi. Bước X ghi được chỉ được tính nếu đồng bộ sang Y qua iCloud. Không bị đếm hai lần. |
| B7 | Apple Watch đang ghép với X, nhưng A đăng nhập trên Y | Bước của Watch đi vào X. Y chỉ thấy nếu iCloud bật. Cần xác nhận chính sách có chấp nhận việc hụt bước này không. |
| B8 | Y được thiết lập bằng cách **khôi phục bản backup của X** | File anchor của X có thể được khôi phục sang Y. Anchor không hợp lệ thì app phải xử lý được: báo lỗi hoặc đọc lại từ mốc. Server không được cộng trùng. **Cần kiểm chứng hành vi thật của HealthKit.** |
| B9 | Hai máy dùng hai Apple ID khác nhau | Giống B2, không có dữ liệu chung. Server gộp theo tài khoản. |
| B10 | Đăng nhập Y lần đầu, server trả về khung cuối cùng đã ghi nhận | Y đọc từ khung đó trừ đi khoảng dư. Phần trùng trong khoảng dư bị server loại theo max. |

## C. Cài lại app và khôi phục

| ID | Kịch bản | Kết quả mong đợi |
|---|---|---|
| C1 | Xoá app, cài lại và đăng nhập cùng tài khoản trong cùng ngày | File anchor bị mất, app đọc lại hôm nay. Server lấy max nên không trả thưởng thêm. |
| C2 | Cài lại khi Keychain vẫn còn `installId` | Server nhận ra đúng thiết bị cũ. |
| C3 | Cài lại khi Keychain đã bị xoá (reset máy) | Máy được coi là thiết bị mới, xử lý như nhóm B. |
| C4 | Xoá app khi còn record chờ gửi | Record đó mất. Nếu HealthKit vẫn còn sample thì lần cài lại sẽ gửi lại được. |
| C5 | Nâng cấp app khi file state hoặc record có cấu trúc mới | Đọc được file cũ, hoặc reset an toàn. Không bị crash, không gửi trùng. |

## D. Gian lận qua nhiều tài khoản

| ID | Kịch bản | Kết quả mong đợi |
|---|---|---|
| D1 | Trên cùng máy X: A nhận bước, đăng xuất, B đăng nhập rồi nhận lại cùng khoảng thời gian | Server từ chối: khung của thiết bị X tại thời điểm T đã thuộc về A. |
| D2 | A dùng máy X, B dùng máy Y, nhưng hai máy dùng **chung một Apple ID** nên thấy cùng sample qua iCloud | Server phát hiện cùng UUID sample hoặc cùng nguồn xuất hiện ở hai tài khoản. Muốn vậy client cần gửi kèm hash của UUID sample. |
| D3 | Đổi giờ hệ thống để tạo bước ở khung tương lai hoặc quá khứ | Server từ chối khung ở tương lai hoặc cũ quá giới hạn. Có thể đối chiếu với `ClockGuard` đang có. |
| D4 | Bước được nhập tay hoặc đến từ app bên thứ ba | Bị loại khỏi tổng tính thưởng, nhưng vẫn ghi log để kiểm tra. |
| D5 | Xoá sample rồi ghi lại sample tương tự | Max theo khung không tăng, nên không nhận thưởng lần hai. |

## E. Nhiều nguồn dữ liệu và chồng lấn

| ID | Kịch bản | Kết quả mong đợi |
|---|---|---|
| E1 | iPhone và Watch cùng ghi một quãng đi bộ | Bước được tính một lần, theo thứ tự ưu tiên nguồn của HealthKit. |
| E2 | Watch đồng bộ trễ vài giờ, sample mới có `startDate` từ trước đó | Anchor vẫn lấy được sample này. Server cập nhật lại khung cũ, và phần chênh lệch được thưởng. |
| E3 | Một sample kéo dài qua nửa đêm | Bước được chia sang đúng hai ngày. |
| E4 | Một sample nằm vắt qua ranh giới khung 5 phút | Bước được chia theo tỉ lệ thời gian (statistics query làm việc này). |
| E5 | Người dùng xoá sample trong app Sức khoẻ | Lượt xoá được ghi log. Thưởng không bị trừ, hoặc bị gắn cờ, theo P4. |

## F. Thời gian và múi giờ

| ID | Kịch bản | Kết quả mong đợi |
|---|---|---|
| F1 | Ranh giới ngày tính theo múi giờ của người dùng | "Ngày" trên server được định nghĩa thống nhất (P5). |
| F2 | Đi du lịch đổi múi giờ trong ngày | Không mất bước và không đếm trùng. Ngày bị dài hoặc ngắn hơn bình thường vẫn được xử lý được. |
| F3 | Sync đúng thời điểm 23:59 sang 00:00 | Bước của hôm trước và hôm sau không bị lẫn sang nhau. Giới hạn bước của ngày được áp dụng đúng ngày. |
| F4 | Đồng hồ hệ thống bị chỉnh lùi hoặc tiến | Có gắn cờ. Không tạo khung trùng hoặc khung ở tương lai. |
| F5 | Chuyển giờ mùa hè (DST) | Khung giờ lặp lại hoặc bị mất được xử lý đúng. |

## G. Quyền HealthKit và trạng thái máy

| ID | Kịch bản | Kết quả mong đợi |
|---|---|---|
| G1 | Người dùng từ chối quyền đọc | HealthKit trả về rỗng mà không báo lỗi. App không được hiểu là "không có bước" rồi ghi đè dữ liệu đã có. |
| G2 | Từ chối quyền trước, sau đó mới cấp | Lần đọc sau phải lấy được các sample bị ẩn trước đó. **Cần kiểm chứng** xem anchor lưu lúc bị từ chối có làm bỏ sót sample không. |
| G3 | Thu hồi quyền sau khi đã sync một thời gian | Dừng ghi log mới, giữ nguyên dữ liệu đã gửi, hiển thị thông báo cho người dùng. |
| G4 | Máy đang khoá khi chạy nền, HealthKit báo không truy cập được database | Query lỗi thì không đẩy anchor lên. Lần mở khoá sau đọc đủ. Code hiện tại đã xử lý: lỗi thì trả nil và không lưu anchor. |
| G5 | Máy không hỗ trợ HealthKit | App tắt passive sync một cách rõ ràng, không crash. |

## H. Vòng đời app và chạy nền

| ID | Kịch bản | Kết quả mong đợi |
|---|---|---|
| H1 | Nhiều trigger đến cùng lúc (wake, refresh, processing) | Hàng đợi chạy tuần tự, không đếm trùng. |
| H2 | App bị kill sau khi lưu record nhưng trước khi lưu anchor | Lần sau đọc lại các sample đó. Server lấy max nên không trùng. |
| H3 | App bị kill sau khi server đã nhận nhưng client chưa nhận được phản hồi | Record vẫn ở trạng thái chờ và được gửi lại. Server nhận ra cùng `recordId` hoặc cùng khung nên không cộng dồn. |
| H4 | BGTask hết thời gian giữa chừng | Phần đã xong được lưu, phần còn lại vẫn chờ. |
| H5 | Bộ nhớ máy đầy, ghi file lỗi | Không đẩy anchor lên khi chưa ghi được record. Hiện `try?` đang nuốt lỗi này, cần xem lại. |
| H6 | `clearLogs` | Xoá record nhưng giữ anchor, nên không gửi lại. Đã có test (`storePersistsHealthKitAnchorAcrossClearAll`). |

## I. Mạng và server

| ID | Kịch bản | Kết quả mong đợi |
|---|---|---|
| I1 | Mất mạng | Record ở trạng thái chờ và dừng ở lỗi đầu tiên. Đã có test (`failedUploadsStayLoggedAndAreRetriedOldestFirst`). |
| I2 | Server trả lỗi 5xx hoặc timeout | Thử gửi lại sau. Không đánh dấu thành công. |
| I3 | Server trả lỗi 4xx do dữ liệu không hợp lệ | Không gửi lại mãi. Đánh dấu `skipped` hoặc lỗi vĩnh viễn. Hiện code vẫn gửi lại lỗi 4xx, cần phân loại lỗi. |
| I4 | Có nhiều record chờ sau thời gian dài offline | Gửi theo thứ tự cũ trước. Cân nhắc gộp nhiều record vào một request. |
| I5 | Server nhận một phần rồi lỗi | Chỉ những record đã được xác nhận mới chuyển sang thành công. |

## J. Dữ liệu cục bộ bị hỏng

| ID | Kịch bản | Kết quả mong đợi |
|---|---|---|
| J1 | File anchor bị hỏng hoặc không giải mã được | Coi như chưa có anchor và đọc lại từ mốc. Server lấy max nên không trùng. |
| J2 | `passive_records.json` bị hỏng | Hiện tại code trả về danh sách rỗng, nên **mất toàn bộ record chờ gửi mà không báo gì**. Cần ít nhất ghi log cảnh báo. |
| J3 | `passive_records.json` rất lớn | Hiệu năng vẫn chấp nhận được. Hiện chưa có giới hạn số record. |

---

## Các chính sách cần quyết định

| # | Câu hỏi |
|---|---|
| P1 | Khi đăng nhập lần đầu: tính bước từ đầu ngày, hay chỉ từ thời điểm đăng nhập? |
| P2 | Khi đăng xuất mà còn record chờ: gửi nốt rồi mới đăng xuất, hay giữ lại cho lần đăng nhập sau của cùng tài khoản, hay bỏ? |
| P3 | Máy bị đá phiên còn dữ liệu chờ: server có nhận dữ liệu có thời gian trước lúc bị đá không? |
| P4 | Sample bị xoá sau khi đã thưởng: giữ nguyên, trừ đi, hay gắn cờ? |
| P5 | "Một ngày" tính theo múi giờ nào: múi giờ của máy tại thời điểm ghi, hay múi giờ cố định của tài khoản? |
| P6 | Một khung thời gian đã thuộc về một tài khoản trên một thiết bị: tài khoản khác có được nhận lại không? (Quyết định case D1.) |

## Lỗ hổng trong code hiện tại

- Record chưa có `accountId`.
- App chưa kiểm tra trạng thái đăng nhập trước khi ghi log hoặc gửi (A6).
- Lỗi khi ghi file đang bị `try?` nuốt mất (H5, J2).
- Chưa phân loại lỗi 4xx và 5xx khi gửi lại (I3).

Các nhóm G, H, I và một phần nhóm J có thể viết unit test ngay. Các nhóm còn lại cần làm login và cách gộp theo khung thời gian ở server trước.
