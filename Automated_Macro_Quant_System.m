% =========================================================================
% 自動化總經與量化交易日報系統 (Automated_Macro_Quant_System.m)
% 整合專案：爬蟲資料庫 + 均值回歸配對 + Gemini API (維度防錯防跑版) + GitHub Actions
% =========================================================================

function Automated_Macro_Quant_System()
    try
        clc; clear; close all;
        fprintf('[%s] 系統啟動，開始執行每日量化與總經資料更新...\n', datestr(now));
        
        %% 參數設定區
        gemini_api_keys = {
            getenv('GEMINI_API_KEY_1'), ...
            getenv('GEMINI_API_KEY_2'), ...
            getenv('GEMINI_API_KEY_3'), ...
            getenv('GEMINI_API_KEY_4'), ...
            getenv('GEMINI_API_KEY_5'), ...
            getenv('GEMINI_API_KEY_6'), ...
            getenv('GEMINI_API_KEY_7'), ...
            getenv('GEMINI_API_KEY_8'), ...
            getenv('GEMINI_API_KEY_9'), ...
            getenv('GEMINI_API_KEY_10')
        }; 
        
        gemini_api_keys = gemini_api_keys(~cellfun(@isempty, gemini_api_keys));
        if isempty(gemini_api_keys)
            error('未偵測到任何 Gemini API Key，請檢查 GitHub Secrets 設定。');
        end
        
        sender_email = getenv('GMAIL_SENDER');      
        sender_pwd = getenv('GMAIL_PWD');           
        receiver_email = getenv('GMAIL_RECEIVER');  
        
        %% Phase 1: 總體經濟、大盤數據與本土籌碼爬蟲
        fprintf('正在爬取全球總經與市場數據...\n');
        
        % 加入了道瓊(^DJI)、費半(^SOX)與標普VIX(^VIX)
        tickers = {'^TWII', '^GSPC', '^IXIC', '^DJI', '^SOX', 'GC=F', 'BTC-USD', 'CL=F', '^TNX', '^VIX'};
        field_keys = {'TWII', 'SP500', 'NASDAQ', 'DJI', 'SOX', 'Gold', 'BTC', 'Oil', 'US10Y', 'VIX'}; 
        names = {'台灣加權指數', '標普500', '納斯達克', '道瓊工業', '費城半導體', '黃金價格', '比特幣', '國際原油', '美10Y公債', '標普VIX'};
        
        market_data = struct();
        start_dt = datetime('today', 'TimeZone', 'local') - calmonths(6); 
        
        for i = 1:length(tickers)
            [~, prices, last_price] = fetch_yahoo_data(tickers{i}, start_dt);
            
            % 計算當日漲跌幅 (%)
            if length(prices) >= 2
                change_pct = ((prices(end) - prices(end-1)) / prices(end-1)) * 100;
            else
                change_pct = 0;
            end
            
            market_data.(field_keys{i}) = struct('Prices', prices, 'Last', last_price, 'ChangePct', change_pct);
            fprintf(' - %s 更新完成 (最新報價: %.2f, 漲跌幅: %+.2f%%)\n', names{i}, last_price, change_pct);
        end
        
        % 額外抓取本土籌碼與情緒數據
        fprintf('正在抓取台股本土籌碼與情緒數據...\n');
        tw_vix_val = fetch_taiwan_vix();
        tw_margin_val = fetch_twse_margin_balance();
        fprintf(' - 台股VIX 更新完成 (最新報價: %.2f)\n', tw_vix_val);
        fprintf(' - 融資餘額 更新完成 (最新餘額: %.2f 億)\n', tw_margin_val);
        
        % 國際大事爬蟲 
        fprintf('正在爬取國際財經頭條...\n');
        news_headlines = fetch_financial_news();
        
        %% Phase 2: 均值回歸與配對分析 (以標普500 vs 台股加權為例)
        fprintf('進行大盤指數之斯皮爾曼相關性與 Z-Score 檢定...\n');
        
        p_sp500 = market_data.SP500.Prices;
        p_twii = market_data.TWII.Prices;
        
        min_len = min(length(p_sp500), length(p_twii));
        p_sp500 = p_sp500(end-min_len+1:end);
        p_twii = p_twii(end-min_len+1:end);
        
        logY = log(p_twii);
        logX = log(p_sp500);
        c = cov(logX, logY);
        current_beta = c(1,2) / c(1,1);
        
        spread = logY - current_beta * logX;
        z_score = (spread(end) - mean(spread)) / std(spread);
        
        %% Phase 3: 建立「程式驅動表頭」與呼叫 Gemini API
        fprintf('正在呼叫 Gemini API 進行資訊整合...\n');
        
        % 1. 由程式直接生成 100% 準確的一行一列報價表頭
        market_header = sprintf([...
            '========================================================\n', ...
            '📊【程式自動追蹤 - 全球市場與風險指標】\n', ...
            '========================================================\n', ...
            '標普 VIX : %8.2f (%+.2f%%)\n', ...
            '台股 VIX : %8.2f\n', ...
            '台股加權 : %8.2f (%+.2f%%)\n', ...
            '融資餘額 : %8.2f 億\n', ...
            '標普 500 : %8.2f (%+.2f%%)\n', ...
            '納斯達克 : %8.2f (%+.2f%%)\n', ...
            '道瓊工業 : %8.2f (%+.2f%%)\n', ...
            '費城半導 : %8.2f (%+.2f%%)\n', ...
            '美10Y公債: %8.2f (%+.2f%%)\n', ...
            '比 特 幣 : %8.2f (%+.2f%%)\n', ...
            '黃金價格 : %8.2f (%+.2f%%)\n', ...
            '國際原油 : %8.2f (%+.2f%%)\n', ...
            '--------------------------------------------------------\n', ...
            '【配對訊號 (S&P 500 vs 台股)】價差 Z-Score: %.2f\n', ...
            '========================================================\n\n'], ...
            market_data.VIX.Last, market_data.VIX.ChangePct, ...
            tw_vix_val, ...
            market_data.TWII.Last, market_data.TWII.ChangePct, ...
            tw_margin_val, ...
            market_data.SP500.Last, market_data.SP500.ChangePct, ...
            market_data.NASDAQ.Last, market_data.NASDAQ.ChangePct, ...
            market_data.DJI.Last, market_data.DJI.ChangePct, ...
            market_data.SOX.Last, market_data.SOX.ChangePct, ...
            market_data.US10Y.Last, market_data.US10Y.ChangePct, ...
            market_data.BTC.Last, market_data.BTC.ChangePct, ...
            market_data.Gold.Last, market_data.Gold.ChangePct, ...
            market_data.Oil.Last, market_data.Oil.ChangePct, ...
            z_score);

        % 2. 餵給 AI 的 Prompt (包含所有新擴充的數據)
        prompt = sprintf([...
            '你是一位專業且俐落的財經晨報主播。請根據以下最新數據與新聞，產出一份「一分鐘完讀」的快訊版晨報，語氣明快、精準、直接給結論。\n\n', ...
            '【市場最新報價與籌碼狀態】\n', ...
            '標普VIX: %.2f | 台股VIX: %.2f | 融資餘額: %.2f億\n', ...
            '道瓊: %.2f | 費半: %.2f | 台股: %.2f\n', ...
            '標普500: %.2f | 納斯達克: %.2f | 美10Y債: %.2f\n', ...
            '黃金: %.2f | 原油: %.2f | 比特幣: %.2f\n\n', ...
            '【配對訊號 (S&P 500 vs 台股加權)】\n', ...
            '價差 Z-Score: %.2f\n\n', ...
            '【國際財經大事】\n%s\n\n', ...
            '【任務要求（嚴格遵守）】\n', ...
            '1. 【市場速讀】：一句話總結今日全球市場主旋律與關鍵大事。\n', ...
            '2. 【資金前瞻】：根據「美債殖利率」、「大宗商品」與「VIX恐慌指數」的波動，指出對「美股」與「台股」板塊的潛在資金推力或壓力。\n', ...
            '3. 【籌碼解讀】：結合「融資餘額」變化，判斷台股散戶籌碼是否過熱或恐慌殺出。\n', ...
            '4. 【量化定調】：結合 Z-Score 數值給出極簡的操作提示。\n', ...
            '5. 【格式限制】：總字數嚴格控制在 250 字內，全程條列式。\n', ...
            '6. 【重要排版】：絕對不要在報告中重複列出詳細報價與數據，請直接給出分析結論。'], ...
            market_data.VIX.Last, tw_vix_val, tw_margin_val, ...
            market_data.DJI.Last, market_data.SOX.Last, market_data.TWII.Last, ...
            market_data.SP500.Last, market_data.NASDAQ.Last, market_data.US10Y.Last, ...
            market_data.Gold.Last, market_data.Oil.Last, market_data.BTC.Last, ...
            z_score, news_headlines);
            
        report_content = call_gemini_api_with_rotation(prompt, gemini_api_keys);
        fprintf('\n=== Gemini 報告生成成功 ===\n');
        
        %% Phase 4: 組合並發送 Gmail
        % 【維度防呆機制】: 將 API回傳內容強制轉型字串並用換行符合併，避免 MATLAB 發生矩陣維度不匹配的錯誤
        report_str = strjoin(string(report_content), char(10));
        final_report = char(string(market_header) + report_str);
        
        fprintf('正在透過 Gmail 發送日報...\n');
        send_report_to_gmail(sender_email, sender_pwd, receiver_email, final_report);
        
        fprintf('[%s] 系統全部執行完畢！\n', datestr(now));
        
    catch ME
        fprintf('系統執行發生嚴重錯誤: %s\n', ME.message);
    end
end

% =========================================================================
% 輔助函數 (Helper Functions)
% =========================================================================

% 1. Yahoo Finance 歷史資料爬蟲
function [timestamps, prices, last_price] = fetch_yahoo_data(ticker, start_dt)
    t_now = datetime('now', 'TimeZone', 'local');
    period2 = num2str(round(posixtime(t_now)));
    
    if isempty(start_dt.TimeZone)
        start_dt.TimeZone = 'local';
    end
    period1 = num2str(round(posixtime(start_dt)));
    
    url = sprintf('https://query2.finance.yahoo.com/v8/finance/chart/%s?period1=%s&period2=%s&interval=1d', ticker, period1, period2);
    options = weboptions('UserAgent', 'Mozilla/5.0', 'Timeout', 20);
    
    try
        data = webread(url, options);
        if iscell(data.chart.result)
            res = data.chart.result{1};
        else
            res = data.chart.result(1);
        end
        timestamps = double(res.timestamp(:));
        prices = double(res.indicators.quote(1).close(:)); 
        
        valid_idx = ~isnan(prices);
        timestamps = timestamps(valid_idx);
        prices = prices(valid_idx);
        last_price = prices(end);
    catch
        timestamps = []; prices = []; last_price = NaN;
    end
end

% 2. 爬取台股大盤融資餘額 (TWSE API)
function margin_bal = fetch_twse_margin_balance()
    try
        url = 'https://www.twse.com.tw/exchangeReport/MI_MARGN?response=json&selectType=MS';
        options = weboptions('Timeout', 15);
        data = webread(url, options);
        % 從信用交易統計表中抓取「今日餘額」的「融資金額(仟元)」(通常在第5列, 第6欄)
        val_str = data.tables{1}.data{5, 6}; 
        margin_bal = str2double(strrep(val_str, ',', '')) / 100000; % 轉換為億元
    catch
        margin_bal = NaN;
    end
end

% 3. 抓取台股VIX (網頁爬蟲)
function tw_vix = fetch_taiwan_vix()
    try
        % 台灣期交所已停編官方VIX，改向財經平台請求最新報價
        url = 'https://www.wantgoo.com/index/vixtwn';
        options = weboptions('UserAgent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)', 'Timeout', 15);
        html = webread(url, options);
        % 使用正規表達式精準抓取最新報價
        tokens = regexp(html, 'class="price[^>]*>([\d\.]+)<', 'tokens');
        if ~isempty(tokens)
            tw_vix = str2double(tokens{1}{1});
        else
            tw_vix = NaN;
        end
    catch
        tw_vix = NaN;
    end
end

% 4. 爬取國際財經新聞 (RSS)
function headlines = fetch_financial_news()
    try
        rss_url = 'https://finance.yahoo.com/news/rssindex';
        options = weboptions('Timeout', 15);
        rss_data = webread(rss_url, options);
        
        % 【維度防呆機制】: 採用字串加法取代陣列串接
        headlines_str = "";
        items = rss_data.channel.item;
        num_items = min(3, length(items));
        for i = 1:num_items
            headlines_str = headlines_str + "- " + string(items(i).title) + char(10);
        end
        headlines = char(headlines_str);
    catch
        headlines = '- 無法取得最新國際新聞。';
    end
end

% 5. 多金鑰輪替與防封鎖呼叫機制
function report_text = call_gemini_api_with_rotation(prompt, api_keys)
    maxRetries = 9; 
    attempt = 0; 
    success = false; 
    currentKeyIdx = 1; 
    report_text = '';
    
    while attempt < maxRetries && ~success 
        attempt = attempt + 1; 
        
        if attempt > 1 
            cooldown = attempt * 2; 
            fprintf('冷卻 %d 秒後進行第 %d 次重試...\n', cooldown, attempt); 
            pause(cooldown); 
            
            currentKeyIdx = mod(currentKeyIdx, length(api_keys)) + 1; 
            fprintf('已切換至備用金鑰 (Index: %d)，重新分析中...\n', currentKeyIdx);
        end
        
        current_key = api_keys{currentKeyIdx}; 
        url = sprintf('https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=%s', current_key); 
        payload = struct('contents', struct('parts', struct('text', prompt))); 
        options = weboptions('MediaType', 'application/json', 'Timeout', 45, 'RequestMethod', 'post'); 
        
        try
            res = webwrite(url, payload, options); 
            report_text = res.candidates(1).content.parts(1).text; 
            success = true; 
        catch ME
            fprintf('❌ 呼叫失敗 (嘗試 %d/%d)！錯誤訊息: %s\n', attempt, maxRetries, ME.message);
            if attempt >= maxRetries 
                report_text = sprintf('分析失敗。已達最大重試次數 (%d)。錯誤原因: %s', maxRetries, ME.message); 
            end
        end
    end
end

% 6. 寄送 Gmail
function send_report_to_gmail(sender_email, sender_pwd, receiver_email, report_text)
    if isempty(sender_email) || isempty(sender_pwd) || isempty(receiver_email)
        fprintf('Email 寄送失敗: 環境變數未正確讀取。\n');
        return;
    end

    setpref('Internet', 'E_mail', sender_email);
    setpref('Internet', 'SMTP_Server', 'smtp.gmail.com');
    setpref('Internet', 'SMTP_Username', sender_email);
    setpref('Internet', 'SMTP_Password', sender_pwd);
    
    props = java.lang.System.getProperties;
    props.setProperty('mail.smtp.auth', 'true');
    props.setProperty('mail.smtp.ssl.trust', 'smtp.gmail.com');
    props.setProperty('mail.smtp.port', '587');
    props.setProperty('mail.smtp.starttls.enable', 'true');
    
    subject = sprintf('【量化總經快訊晨報】%s', datestr(today, 'yyyy-mm-dd'));
    
    try
        sendmail(receiver_email, subject, report_text);
    catch ME
        fprintf('Email 寄送失敗: %s\n', ME.message);
    end
end
