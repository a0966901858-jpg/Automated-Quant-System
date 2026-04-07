% =========================================================================
% 自動化總經與量化交易日報系統 (Automated_Macro_Quant_System.m)
% 整合專案：爬蟲資料庫 + 均值回歸配對 + 機器學習回測 + Gemini API (多金鑰輪替版) + Gmail
% =========================================================================

function Automated_Macro_Quant_System()
    try
        clc; clear; close all;
        fprintf('[%s] 系統啟動，開始執行每日量化與總經資料更新...\n', datestr(now));
        
        %% 參數設定區
        % 請填入你的多組 Gemini API Keys 以啟用防封鎖輪替機制
       %% 參數設定區 (改用環境變數，保護金鑰安全)
        % 從 GitHub Secrets 讀取多組金鑰
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
        
        sender_email = getenv('GMAIL_SENDER');      % 寄件者 Gmail
        sender_pwd = getenv('GMAIL_PWD');           % Gmail 應用程式密碼
        receiver_email = getenv('GMAIL_RECEIVER');  % 收件者信箱 
        
        %% Phase 1: 總體經濟與大盤數據爬蟲
        fprintf('正在爬取全球總經與市場數據...\n');
        
        % 定義欲爬取的 Yahoo Finance 標的、對應的英文鍵值與中文名稱
        tickers = {'^TWII', '^GSPC', '^IXIC', 'GC=F', 'BTC-USD', 'CL=F', '^TNX'};
        field_keys = {'TWII', 'SP500', 'NASDAQ', 'Gold', 'BTC', 'Oil', 'US10Y'}; % 純英文鍵值，避開中文變數報錯
        names = {'台灣加權指數', '標普500指數', '納斯達克指數', '黃金價格', '比特幣', '國際原油', '美10年期公債殖利率'};
        
        market_data = struct();
        start_dt = datetime('today', 'TimeZone', 'local') - calmonths(6); 
        
        for i = 1:length(tickers)
            [~, prices, last_price] = fetch_yahoo_data(tickers{i}, start_dt);
            % 使用英文鍵值存入 struct
            market_data.(field_keys{i}) = struct('Prices', prices, 'Last', last_price);
            fprintf(' - %s 更新完成 (最新報價: %.2f)\n', names{i}, last_price);
        end
        
        % 國際大事爬蟲 
        fprintf('正在爬取國際財經頭條...\n');
        news_headlines = fetch_financial_news();
        
        %% Phase 2: 均值回歸與配對分析 (以標普500 vs 納斯達克為例)
        fprintf('進行大盤指數之斯皮爾曼相關性與 Z-Score 檢定...\n');
        
        % 使用英文鍵值讀取歷史價格陣列
        p_sp500 = market_data.SP500.Prices;
        p_nasdaq = market_data.NASDAQ.Prices;
        
        % 對齊資料長度
        min_len = min(length(p_sp500), length(p_nasdaq));
        p_sp500 = p_sp500(end-min_len+1:end);
        p_nasdaq = p_nasdaq(end-min_len+1:end);
        
        % 計算報酬率與斯皮爾曼相關係數
        ret_sp500 = diff(p_sp500) ./ p_sp500(1:end-1);
        ret_nasdaq = diff(p_nasdaq) ./ p_nasdaq(1:end-1);
        spearman_corr = corr(ret_sp500, ret_nasdaq, 'Type', 'Spearman');
        
        % 動態 Beta 與 Z-Score 運算
        logY = log(p_nasdaq);
        logX = log(p_sp500);
        c = cov(logX, logY);
        current_beta = c(1,2) / c(1,1);
        
        spread = logY - current_beta * logX;
        z_score = (spread(end) - mean(spread)) / std(spread);
        
        %% Phase 3: 呼叫 Gemini API 產出投資日報 (加入多金鑰輪替機制)
        fprintf('正在呼叫 Gemini API 進行資訊整合...\n');
        
        prompt = sprintf([...
            '你是一名精通總體經濟與量化交易的資深避險基金經理人。請根據以下最新爬取之數據，撰寫一份專業的每日投資日報。\n\n', ...
            '【全球市場最新報價】\n', ...
            '- 台灣加權指數: %.2f\n', ...
            '- 標普500指數 (S&P 500): %.2f\n', ...
            '- 納斯達克指數 (NASDAQ): %.2f\n', ...
            '- 黃金價格: %.2f\n', ...
            '- 比特幣: %.2f\n', ...
            '- 國際原油: %.2f\n', ...
            '- 美國10年期公債殖利率: %.2f%%\n\n', ...
            '【量化配對分析 (S&P 500 vs NASDAQ)】\n', ...
            '- 斯皮爾曼相關係數: %.4f\n', ...
            '- 當前價差 Z-Score: %.2f (大於2代表科技股相對大盤嚴重溢價，小於-2代表相對折價)\n\n', ...
            '【今日國際財經大事】\n%s\n\n', ...
            '【任務要求】\n', ...
            '1. 總結今日總經數據與市場情緒。\n', ...
            '2. 根據美國10年期公債殖利率的變化，分析對科技股 ETF 的潛在影響。\n', ...
            '3. 依據量化配對分析的 Z-Score 給出具體的部位調整建議（順勢或均值回歸）。\n', ...
            '4. 語氣冷靜、客觀、專業，使用繁體中文，並善用列點排版。'], ...
            market_data.TWII.Last, market_data.SP500.Last, market_data.NASDAQ.Last, ...
            market_data.Gold.Last, market_data.BTC.Last, market_data.Oil.Last, market_data.US10Y.Last, ...
            spearman_corr, z_score, news_headlines);
            
        % 傳入金鑰陣列，啟動防封鎖輪替機制
        report_content = call_gemini_api_with_rotation(prompt, gemini_api_keys);
        fprintf('\n=== Gemini 報告生成成功 ===\n');
        
        %% Phase 4: 發送 Gmail
        fprintf('正在透過 Gmail 發送日報...\n');
        send_report_to_gmail(sender_email, sender_pwd, receiver_email, report_content);
        
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
    options = weboptions('UserAgent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36', 'Timeout', 20);
    
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

% 2. 爬取國際財經新聞 (RSS)
function headlines = fetch_financial_news()
    try
        rss_url = 'https://finance.yahoo.com/news/rssindex';
        options = weboptions('Timeout', 15);
        rss_data = webread(rss_url, options);
        
        headlines = '';
        items = rss_data.channel.item;
        num_items = min(3, length(items));
        for i = 1:num_items
            headlines = [headlines, '- ', items(i).title, char(10)];
        end
    catch
        headlines = '- 無法取得最新國際新聞。';
    end
end

% 3. 多金鑰輪替與防封鎖呼叫機制
function report_text = call_gemini_api_with_rotation(prompt, api_keys)
    maxRetries = 9; 
    attempt = 0; 
    success = false; 
    currentKeyIdx = 1; 
    report_text = '';
    
    while attempt < maxRetries && ~success 
        attempt = attempt + 1; 
        
        if attempt > 1 
            % 動態冷卻時間：隨著失敗次數增加而拉長等待時間
            cooldown = attempt * 2; 
            fprintf('API 忙碌或無回應，冷卻 %d 秒後進行第 %d 次重試...\n', cooldown, attempt); 
            pause(cooldown); 
            
            % 輪替金鑰陣列索引
            currentKeyIdx = mod(currentKeyIdx, length(api_keys)) + 1; 
            fprintf('已切換至備用金鑰 (Index: %d)，重新分析中...\n', currentKeyIdx);
        end
        
        current_key = api_keys{currentKeyIdx}; 
        url = sprintf('https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=%s', current_key); 
        payload = struct('contents', struct('parts', struct('text', prompt))); 
        options = weboptions('MediaType', 'application/json', 'Timeout', 45, 'RequestMethod', 'post'); 
        
        try
            res = webwrite(url, payload, options); 
            report_text = res.candidates(1).content.parts(1).text; 
            success = true; 
        catch ME
            if attempt >= maxRetries 
                report_text = sprintf('分析失敗。已達最大重試次數 (%d)。錯誤原因: %s', maxRetries, ME.message); 
            end
        end
    end
end

% 4. 寄送 Gmail
function send_report_to_gmail(sender_email, sender_pwd, receiver_email, report_text)
    setpref('Internet', 'E_mail', sender_email);
    setpref('Internet', 'SMTP_Server', 'smtp.gmail.com');
    setpref('Internet', 'SMTP_Username', sender_email);
    setpref('Internet', 'SMTP_Password', sender_pwd);
    
    props = java.lang.System.getProperties;
    props.setProperty('mail.smtp.auth', 'true');
    props.setProperty('mail.smtp.ssl.trust', 'smtp.gmail.com');
    props.setProperty('mail.smtp.port', '587');
    props.setProperty('mail.smtp.starttls.enable', 'true');
    
    subject = sprintf('【量化總經 AI 報告】%s', datestr(today, 'yyyy-mm-dd'));
    
    try
        sendmail(receiver_email, subject, report_text);
    catch ME
        fprintf('Email 寄送失敗: %s\n', ME.message);
    end
end