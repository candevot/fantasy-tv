import 'package:flutter/material.dart';

import '../services/app_info.dart';
import '../theme.dart';
import 'category_page.dart';

class LegalSection {
  const LegalSection(this.heading, this.body);
  final String heading;
  final String body;
}

class LegalDocument {
  const LegalDocument({
    required this.title,
    required this.updatedAt,
    required this.sections,
  });

  final String title;
  final String updatedAt;
  final List<LegalSection> sections;
}

/// 内置的隐私政策与用户协议（不联网加载，离线也能读）。
const LegalDocument privacyPolicy = LegalDocument(
  title: '隐私政策',
  updatedAt: '2026 年 11 月',
  sections: <LegalSection>[
    LegalSection(
      '一、我们收集的信息',
      '1. 账号信息：注册或登录时，服务器会保存你的账号、昵称、头像和个性签名。密码只用于服务端校验，本机不保存明文密码；登录凭证保存在本机，用于维持登录状态。\n'
          '2. 使用数据：观看历史、收藏、播放进度和离线缓存记录默认保存在本机；登录后，这些数据会同步到你当前配置的服务器，以便换设备后继续使用。\n'
          '3. 意见反馈：提交反馈时会发送反馈内容、你填写的联系方式（选填）和账号 uid，仅用于定位和处理问题。\n'
          '4. 更新检查：检查更新时只发送当前版本号和必要请求头，不包含个人身份信息。',
    ),
    LegalSection(
      '二、设备权限',
      '1. 网络权限：用于加载页面、播放视频、登录、同步数据和提交反馈。\n'
          '2. 存储权限：用于保存离线缓存。你可以选择「手机存储」或「应用私有」目录；选择应用私有目录时不需要额外存储权限。\n'
          '3. 相册权限：仅在你主动更换头像时读取你选中的图片，不会扫描相册中的其他内容。\n'
          '4. 本应用不收集通讯录、精确位置、短信、通话记录等敏感信息，也不集成广告追踪 SDK。',
    ),
    LegalSection(
      '三、信息的存储与保护',
      '1. 本机数据保存在 SharedPreferences 和应用专属文件中；离线视频保存在你选择的下载目录。\n'
          '2. 服务器地址由你在 App 内配置，数据只会发送到该服务器。建议使用 HTTPS 部署，避免明文传输。\n'
          '3. 卸载 App 会删除应用私有数据；保存在公共 Download 目录中的离线文件需要你手动删除。\n'
          '4. 我们会采取合理的技术措施保护数据，但互联网传输无法保证绝对安全，请妥善保管账号密码。',
    ),
    LegalSection(
      '四、第三方组件',
      '本应用使用 Flutter、ExoPlayer(Media3) 等开源组件完成界面和播放能力，这些组件不会用于广告追踪。片源由你所配置的服务器或公开测试流提供，其内容与隐私实践由对应提供方负责。',
    ),
    LegalSection(
      '五、你的权利',
      '你可以随时在「我的」中修改昵称、头像和签名，退出登录，或在「设置 → 下载与缓存」中清除全部离线缓存。如需注销账号、删除服务器上的数据或咨询隐私问题，请通过下方邮箱联系我们。',
    ),
    LegalSection(
      '六、政策更新与联系我们',
      '本政策可能随功能调整而更新，更新后会在本页展示。若你对本政策有疑问，请联系：${AppInfo.contactEmail}。',
    ),
  ],
);

const LegalDocument userAgreement = LegalDocument(
  title: '用户协议',
  updatedAt: '2026 年 11 月',
  sections: <LegalSection>[
    LegalSection(
      '一、服务说明',
      '幻想影视是一款本地影视播放工具，提供播放、收藏、观看历史、离线缓存、一起看等功能。片源由你配置的服务器或公开测试流提供，本应用不主动提供、存储或分发影视内容。',
    ),
    LegalSection(
      '二、账号与安全',
      '你需要使用账号登录后使用同步、评论、一起看等功能。请妥善保管账号和密码，不要与他人共享；因个人保管不当造成的损失由你自行承担。发现账号异常时，请及时修改密码并联系我们。',
    ),
    LegalSection(
      '三、使用规范',
      '你承诺遵守当地法律法规，不利用本应用传播违法、侵权、淫秽、暴力或危害公共安全的内容，不进行恶意刷接口、爬取数据、攻击服务器等行为。违反规范时，我们有权限制或终止相关功能的使用。',
    ),
    LegalSection(
      '四、内容与版权',
      '请仅播放你拥有合法访问权限的内容。影视作品的著作权归权利人所有；因使用第三方片源产生的版权纠纷，由内容提供方或使用者自行承担。本应用会在收到有效通知后配合处理侵权内容。',
    ),
    LegalSection(
      '五、离线缓存',
      '离线缓存仅用于个人观看，请勿传播、出售或用于商业用途。缓存文件保存在你选择的下载目录中，可能因清理、卸载、系统回收空间或片源失效而丢失，请勿将其作为唯一保存方式。',
    ),
    LegalSection(
      '六、免责声明',
      '本应用按「现状」提供，不对第三方片源的可用性、清晰度、更新速度作保证。因网络、设备、第三方服务或不可抗力导致的中断或损失，在法律允许的范围内不承担责任。',
    ),
    LegalSection(
      '七、协议变更与终止',
      '我们可能根据功能或法律要求更新本协议，更新后在本页展示，继续使用即视为接受更新后的协议。若你不同意，可停止使用并卸载本应用。',
    ),
    LegalSection(
      '八、联系我们',
      '如对本协议有疑问、投诉或建议，请联系：${AppInfo.contactEmail}。',
    ),
  ],
);

class LegalPage extends StatelessWidget {
  const LegalPage({super.key, required this.document});

  final LegalDocument document;

  @override
  Widget build(BuildContext context) {
    return FxPageScaffold(
      title: document.title,
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 32),
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              '最近更新：${document.updatedAt}',
              style: const TextStyle(fontSize: 10.5, color: Fx.sub),
            ),
          ),
          for (final section in document.sections) ...[
            GlassCard(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 15),
              radius: 18,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    section.heading,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.35,
                      fontWeight: FontWeight.w700,
                      color: Fx.ink,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    section.body,
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.75,
                      color: Fx.sub,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 4),
          Center(
            child: Text(
              '幻想影视 · ${AppInfo.displayVersion}',
              style: const TextStyle(
                fontSize: 9.5,
                color: Color(0xFFB3BECD),
                letterSpacing: .4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
